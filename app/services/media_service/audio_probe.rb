# app/services/media_service/audio_probe.rb

require "open3"

module MediaService
  # Reads the true playable length of an uploaded audio file.
  #
  # The file itself — not the client — is the source of truth for how long it
  # plays: older app builds reported the wall-clock timer as `duration_secs`,
  # which runs longer than the captured audio whenever background chunks get
  # dropped (testers: "duration longer than the file").
  #
  # - PCM WAV is parsed straight from the RIFF header (exact, no dependency).
  # - Everything else (mp3/m4a/aac/ogg/flac) is a best-effort `ffprobe`
  #   (ffmpeg ships in the image); nil when the probe fails, so the caller
  #   keeps whatever value it already has.
  module AudioProbe
    WAV_HEADER_BYTES = 44
    MAX_SECONDS = 24 * 60 * 60

    class << self
      # Whole seconds, or nil when the length cannot be determined.
      def duration_secs(file)
        return nil unless file

        wav_duration_secs(file) || ffprobe_duration_secs(file)
      rescue StandardError
        nil
      end

      # 16-bit+ PCM WAVs carry exact numbers: the header's byte rate and data
      # chunk size give the playable length without decoding a single sample.
      def wav_duration_secs(file)
        io = file.respond_to?(:tempfile) ? file.tempfile : file
        return nil unless io.respond_to?(:read)

        io.rewind
        header = io.read(WAV_HEADER_BYTES).to_s
        return nil unless header.bytesize >= WAV_HEADER_BYTES
        return nil unless header[0, 4] == "RIFF" && header[8, 4] == "WAVE"

        byte_rate = header[28, 4].unpack1("V").to_i
        return nil if byte_rate <= 0

        data_size = header[40, 4].unpack1("V").to_i
        total_size = io.size.to_i
        if data_size <= 0 || data_size > total_size
          data_size = total_size - WAV_HEADER_BYTES
        end
        return nil if data_size <= 0

        clamp_seconds((data_size.to_f / byte_rate).round)
      rescue StandardError
        nil
      ensure
        io.rewind if io.respond_to?(:rewind)
      end

      def ffprobe_duration_secs(file)
        path = file.respond_to?(:tempfile) ? file.tempfile.path : file.path
        return nil unless path && File.exist?(path)

        output, status = Open3.capture2(
          "ffprobe", "-v", "error",
          "-show_entries", "format=duration",
          "-of", "default=noprint_wrappers=1:nokey=1",
          path
        )
        return nil unless status.success?

        seconds = Float(output.strip, exception: false)
        return nil if seconds.nil? || !seconds.finite? || seconds <= 0

        clamp_seconds(seconds.round)
      rescue StandardError
        nil
      end

      private

      def clamp_seconds(seconds)
        seconds.to_i.clamp(1, MAX_SECONDS)
      end
    end
  end
end
