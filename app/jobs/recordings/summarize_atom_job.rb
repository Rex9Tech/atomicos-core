# app/jobs/recordings/summarize_atom_job.rb
#
# Generates the AI summary for a finished recording's atom. Runs in the
# background: a long recording (10+ minutes) produces a transcript whose
# summary takes longer than the mobile client's HTTP timeout, so doing this
# inline made "End recording" fail on the device even though the atom had
# already been created.
class Recordings::SummarizeAtomJob < ApplicationJob
  queue_as :default

  def perform(atom_id, transcript)
    atom = Atom.find_by(id: atom_id)
    return if atom.nil?
    # Idempotent: a retried finish (or a second enqueue) never re-summarizes.
    return if atom.summary_blocks.present?

    unless CreditsService.charge_meeting_summary(
      user: atom.user,
      metadata: { "atom_id" => atom.id, "flow" => "recording_finish" }
    )
      Rails.logger.info(
        "[RECORDING-SUMMARY] skipping atom #{atom.id}: insufficient credits"
      )
      return
    end

    result = Ai::RunService.execute_summarize(
      user: atom.user,
      text: transcript.to_s,
      request_metadata: { "atom_id" => atom.id, "flow" => "recording_finish" }
    )
    summary = AiService::Client.text_from(result)
    if summary.blank?
      Rails.logger.warn(
        "[RECORDING-SUMMARY] empty summary for atom #{atom.id}: " \
          "#{result[:error].presence || 'no response'}"
      )
      return
    end

    atom.update!(summary_blocks: [ { "type" => "summary", "text" => summary } ])
    broadcast_atom_updated(atom)
  rescue StandardError => e
    Rails.logger.error(
      "[RECORDING-SUMMARY] atom #{atom_id} failed: #{e.class}: #{e.message}"
    )
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
