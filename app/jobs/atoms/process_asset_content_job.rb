# app/jobs/atoms/process_asset_content_job.rb
#
# Transcribes + summarizes an atom's uploaded audio, then marks it completed
# and broadcasts, so every client refreshes. Runs OFF the upload request:
# the provider can 503/429 transiently, and the old inline path skipped
# processing silently when that happened (testers saw atoms with no summary
# or transcript at all).
class Atoms::ProcessAssetContentJob < ApplicationJob
  LOG_PREFIX = "[ATOM-ASSET]".freeze

  queue_as :default

  # Transcription + summarization are provider calls that usually recover on
  # their own (503/429 windows roll within a minute): retry on a short fixed
  # cadence, then surface the failure on the atom.
  retry_on StandardError, wait: 20.seconds, attempts: 5 do |job, error|
    atom = Atom.find_by(id: job.arguments.first)
    atom&.update(status: AtomConstants::Status::FAILED)
    Rails.logger.error(
      "#{LOG_PREFIX} Gave up on atom #{job.arguments.first}: #{error.message}"
    )
  end

  def perform(atom_id)
    atom = Atom.find(atom_id)
    asset = atom.assets
                .where(format: AssetConstants::AssetFormat::AUDIO)
                .order(created_at: :desc)
                .first
    return if asset.blank?

    transcript = transcribe(asset, atom)
    raise "empty transcript" if transcript.blank?

    summary = summarize(atom, transcript)
    raise "empty summary" if summary.blank?

    atom.update!(
      status: AtomConstants::Status::COMPLETED,
      transcript_segments: [ { "speaker" => "Speaker", "text" => transcript } ],
      summary_blocks: [ { "type" => "summary", "text" => summary } ]
    )

    broadcast(atom)
  rescue ActiveRecord::RecordNotFound
    # Atom deleted while queued — nothing to do.
  end

  private

  def transcribe(asset, atom)
    result = SpeechService::Client.speech_to_text_from_url(
      audio_url: asset.url,
      language: atom.metadata["stt_language"].presence
    )
    raise "stt error: #{result[:error]}" if result[:error].present?

    result[:text].to_s.strip
  end

  # Summaries run through Ai::RunService so each call is recorded in ai_runs
  # (tokens + OpenRouter-priced cost) — previously they bypassed run logging.
  def summarize(atom, text)
    result = Ai::RunService.execute_summarize(
      user: atom.user,
      text: text,
      request_metadata: { "atom_id" => atom.id, "flow" => "asset_upload" }
    )
    raise "summarize error: #{result[:error]}" if result[:error].present?

    AiService::Client.text_from(result).to_s.strip
  end

  def broadcast(atom)
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
