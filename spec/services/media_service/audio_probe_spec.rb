# spec/services/media_service/audio_probe_spec.rb

require "rails_helper"
require "tmpdir"

RSpec.describe MediaService::AudioProbe do
  # Builds a real 16-bit PCM WAV on disk: `data_bytes` bytes of audio after a
  # canonical 44-byte RIFF header.
  def build_wav(path, data_bytes:, sample_rate: 16_000, channels: 1, bits: 16)
    byte_rate = sample_rate * channels * (bits / 8)
    block_align = channels * (bits / 8)

    header = +"RIFF"
    header << [ 36 + data_bytes ].pack("V")
    header << "WAVE"
    header << "fmt "
    header << [ 16 ].pack("V")
    header << [ 1 ].pack("v") # PCM
    header << [ channels ].pack("v")
    header << [ sample_rate ].pack("V")
    header << [ byte_rate ].pack("V")
    header << [ block_align ].pack("v")
    header << [ bits ].pack("v")
    header << "data"
    header << [ data_bytes ].pack("V")

    File.binwrite(path, header + ("\x00" * data_bytes))
    path
  end

  around do |example|
    Dir.mktmpdir("audio-probe") { |dir| @dir = dir; example.run }
  end

  describe ".wav_duration_secs" do
    it "reads whole seconds straight from the header byte rate" do
      # 16 kHz mono 16-bit → 32,000 bytes per second of audio.
      path = build_wav(File.join(@dir, "three.wav"), data_bytes: 32_000 * 3)

      expect(described_class.wav_duration_secs(File.new(path))).to eq(3)
    end

    it "rounds partial seconds like the app does" do
      path = build_wav(File.join(@dir, "round.wav"), data_bytes: 32_000 * 3 + 16_000)

      expect(described_class.wav_duration_secs(File.new(path))).to eq(4)
    end

    it "honours the header's own byte rate for other shapes (44.1 kHz stereo)" do
      path = build_wav(
        File.join(@dir, "stereo.wav"),
        data_bytes: 176_400 * 2,
        sample_rate: 44_100,
        channels: 2
      )

      expect(described_class.wav_duration_secs(File.new(path))).to eq(2)
    end

    it "falls back to the file size when the data chunk size is a placeholder" do
      path = build_wav(File.join(@dir, "placeholder.wav"), data_bytes: 32_000 * 5)
      # Zero out the data chunk size (56..60) — pre-finalize WAVs carry it.
      File.open(path, "r+b") { |f| f.seek(40); f.write([ 0 ].pack("V")) }

      expect(described_class.wav_duration_secs(File.new(path))).to eq(5)
    end

    it "returns nil for non-RIFF files" do
      path = File.join(@dir, "notes.txt")
      File.write(path, "just some text, definitely not audio")

      expect(described_class.wav_duration_secs(File.new(path))).to be_nil
    end

    it "returns nil for empty audio payloads" do
      path = build_wav(File.join(@dir, "empty.wav"), data_bytes: 0)

      expect(described_class.wav_duration_secs(File.new(path))).to be_nil
    end
  end

  describe ".duration_secs" do
    it "takes the WAV fast path for .wav uploads" do
      path = build_wav(File.join(@dir, "plain.wav"), data_bytes: 32_000 * 7)

      expect(described_class.duration_secs(File.new(path))).to eq(7)
    end

    it "reads the UploadedFile shape the controllers pass" do
      path = build_wav(File.join(@dir, "uploaded.wav"), data_bytes: 32_000 * 6)
      uploaded = ActionDispatch::Http::UploadedFile.new(
        tempfile: File.open(path, "rb"),
        filename: "recording.wav",
        type: "audio/wav"
      )

      expect(described_class.duration_secs(uploaded)).to eq(6)
    end

    it "returns nil when the input cannot be read" do
      expect(described_class.duration_secs("not-a-file")).to be_nil
      expect(described_class.duration_secs(nil)).to be_nil
    end

    it "uses ffprobe for compressed audio when available", :aggregate_failures do
      skip "ffprobe is not installed" unless system("command -v ffprobe > /dev/null 2>&1")

      wav = build_wav(File.join(@dir, "probe.wav"), data_bytes: 32_000 * 2)
      mp3 = File.join(@dir, "probe.mp3")
      system(
        "ffmpeg", "-v", "error", "-y", "-i", wav, "-codec:a", "libmp3lame", mp3,
        out: File::NULL, err: File::NULL
      )
      skip "ffmpeg could not encode the sample" unless File.exist?(mp3)

      expect(described_class.duration_secs(File.new(mp3))).to eq(2)
    end
  end
end
