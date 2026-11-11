# test/services/speech_service/diarizer_full_audio_test.rb
#
# Full-recording diarization: audio is walked in chunks and each chunk gets
# the voices seen so far as reference samples, so speaker numbering stays
# stable end to end. Provider calls are faked by subclassing — this pins the
# chunking, sample chaining and time-offset logic.
require "test_helper"

class SpeechService::DiarizerFullAudioTest < ActiveSupport::TestCase
  BPS = 32_000

  # Two voices in every chunk, both survive across the chunk boundary.
  # Returns times relative to the whole clip (samples included), like the model.
  class TwoVoiceDiarizer < SpeechService::Diarizer
    class << self
      attr_accessor :calls

      def diarize(pcm:, language: nil, samples: [])
        (self.calls ||= []) << { bytes: pcm.bytesize, samples: samples.length }
        prefix = samples.sum { |sample| sample[:pcm].bytesize } / 32_000.0
        [
          { speaker: "Speaker 1", text: "hello there", start_s: prefix + 1.0, end_s: prefix + 2.0 },
          { speaker: "Speaker 2", text: "hi back", start_s: prefix + 3.0, end_s: prefix + 4.0 }
        ]
      end
    end
  end

  class AlwaysFailingDiarizer < SpeechService::Diarizer
    def self.diarize(pcm:, language: nil, samples: [])
      nil
    end
  end

  # First chunk succeeds, later chunks fail — a partial transcript is kept.
  class LaterFailingDiarizer < SpeechService::Diarizer
    class << self
      attr_accessor :calls

      def diarize(pcm:, language: nil, samples: [])
        self.calls = (self.calls || 0) + 1
        return nil if calls > 1

        [ { speaker: "Speaker 1", text: "only chunk one", start_s: 0.5, end_s: 1.5 } ]
      end
    end
  end

  def build_wav(seconds)
    pcm = "\x10\x00".b * (seconds * BPS / 2)
    header = [
      "RIFF", pcm.bytesize + 36, "WAVE", "fmt ", 16, 1, 1, 16_000,
      BPS, 2, 16, "data", pcm.bytesize
    ].pack("a4Va4a4VvvVVvva4V")
    header + pcm
  end

  test "keeps speaker numbers stable across chunks via sample chaining" do
    TwoVoiceDiarizer.calls = []
    result = TwoVoiceDiarizer.new.diarize_full_audio(
      bytes: build_wav(6 * 60), language: "en-US"
    )

    assert result.present?
    assert_equal [ "Speaker 1", "Speaker 2" ], result.map { |s| s[:speaker] }.uniq
    # Chunk 1 had no samples; chunk 2 receives the two voices captured from it.
    assert_equal [ 0, 2 ], TwoVoiceDiarizer.calls.map { |call| call[:samples] }
    # Second chunk's segments are offset past the first chunk's 300 seconds.
    assert_operator result[2][:start_s], :>=, 300.0
    assert_equal "Speaker 1", result[2][:speaker]
  end

  test "returns nil when the first chunk fails" do
    assert_nil AlwaysFailingDiarizer.new.diarize_full_audio(
      bytes: build_wav(60), language: "en-US"
    )
  end

  test "keeps partial results when a later chunk fails" do
    LaterFailingDiarizer.calls = 0
    result = LaterFailingDiarizer.new.diarize_full_audio(
      bytes: build_wav(6 * 60), language: "en-US"
    )

    assert_equal 1, result.length
    assert_equal "Speaker 1", result.first[:speaker]
  end
end
