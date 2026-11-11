# app/jobs/recordings/summarize_atom_job.rb
#
# Generates the AI summary for a finished recording's atom. Runs in the
# background: a long recording (10+ minutes) produces a transcript whose
# summary takes longer than the mobile client's HTTP timeout, so doing this
# inline made "End recording" fail on the device even though the atom had
# already been created.
class Recordings::SummarizeAtomJob < ApplicationJob
  queue_as :default

  # Provider hiccups (429 rate limits, 503 spikes) recover on their own; a
  # summary must not be dropped just because a single call failed. The old
  # behaviour swallowed the error after charging the credit, leaving atoms
  # with no summary and no retry.
  retry_on StandardError, wait: 60.seconds, attempts: 5

  def perform(atom_id, transcript)
    atom = Atom.find_by(id: atom_id)
    return if atom.nil?
    # Idempotent: a retried finish (or a second enqueue) never re-summarizes.
    return if atom.summary_blocks.present?

    # Charged once per atom: retries after transient provider errors must not
    # stack charges. The flag survives across retry attempts.
    unless atom.metadata["summary_charged"].present?
      unless CreditsService.charge_meeting_summary(
        user: atom.user,
        metadata: { "atom_id" => atom.id, "flow" => "recording_finish" }
      )
        Rails.logger.info(
          "[RECORDING-SUMMARY] skipping atom #{atom.id}: insufficient credits"
        )
        return
      end
      atom.update!(metadata: atom.metadata.merge("summary_charged" => true))
    end

    result = Ai::RunService.execute_summarize(
      user: atom.user,
      text: transcript.to_s,
      request_metadata: { "atom_id" => atom.id, "flow" => "recording_finish" }
    )
    summary = AiService::Client.text_from(result)
    if summary.blank?
      # Raise so ActiveJob retries with backoff instead of dropping the summary.
      raise "empty summary: #{result[:error].presence || 'no response'}"
    end

    atom.update!(summary_blocks: [ { "type" => "summary", "text" => summary } ])
    broadcast_atom_updated(atom)
  end

  private

  def broadcast_atom_updated(atom)
    SocketService::Client.broadcast(
      user_id: atom.user_id,
      message: MessageService::Atom.t(MessageService::Atom::ATOM_UPDATED),
      data: {
        type: NotificationConstants::NotificationType::ATOM_UPDATED,
        atom_id: atom.id
      }
    )
  end
end
