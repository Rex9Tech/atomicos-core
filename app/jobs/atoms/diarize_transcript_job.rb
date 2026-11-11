# app/jobs/atoms/diarize_transcript_job.rb
#
# Post-finish speaker diarization: reruns the whole uploaded recording through
# SpeechService::Diarizer so the atom's transcript is labelled end to end —
# the live pipeline can miss the tail of a recording (it diarizes slightly
# behind the audio), and short recordings fall back to unlabelled text when
# the client's coverage check fails.
#
# Runs OFF the upload request like ProcessAssetContentJob: diarization makes
# provider calls that recover on their own (503/429 windows).
class Atoms::DiarizeTranscriptJob < ApplicationJob
  LOG_PREFIX = "[ATOM-DIARIZE]".freeze

  queue_as :default

  retry_on StandardError, wait: 30.seconds, attempts: 4

  def perform(atom_id)
    atom = Atom.find(atom_id)
    return unless atom.source == AtomConstants::Source::MEETING
    return if atom.metadata["diarized"].present?

    asset = atom.assets
                .where(format: AssetConstants::AssetFormat::AUDIO)
                .where.not(type: AssetConstants::AssetType::ATTACHMENT)
                .order(created_at: :desc)
                .first
    return if asset.blank?

    bytes = download(asset.url)
    raise "download failed for #{asset.url}" if bytes.blank?

    segments = SpeechService::Diarizer.diarize_full_audio(
      bytes: bytes,
      language: atom.metadata["stt_language"]
    )
    raise "diarization produced no segments" if segments.blank?

    speaker_count = segments.map { |segment| segment[:speaker] }.uniq.length
    updates = {
      transcript_segments: segments.map do |segment|
        {
          "speaker" => segment[:speaker],
          "text" => segment[:text],
          "start" => segment[:start_s],
          "end" => segment[:end_s]
        }
      end,
      metadata: atom.metadata.merge("diarized" => true)
    }
    updates[:participants_count] = speaker_count if speaker_count > 1
    atom.update!(updates)

    Rails.logger.info(
      "#{LOG_PREFIX} atom #{atom.id}: #{segments.length} segments, #{speaker_count} speakers"
    )
    broadcast(atom)
  rescue ActiveRecord::RecordNotFound
    # Atom deleted while queued — nothing to do.
  end

  private

  def download(url)
    uri = URI.parse(url.to_s)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 20
    http.read_timeout = 180

    response = http.request(Net::HTTP::Get.new(uri.request_uri))
    response.code.to_i == 200 ? response.body.to_s.b : nil
  rescue => e
    Rails.logger.error("#{LOG_PREFIX} download error: #{e.message}")
    nil
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
