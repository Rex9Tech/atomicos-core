require "test_helper"

class Atoms::ProcessAssetContentJobTest < ActiveSupport::TestCase
  def build_user
    User.create!(
      name: "Atom Asset User",
      email: "atomasset-#{SecureRandom.hex(4)}@atomic.test",
      username: "atomasset#{SecureRandom.hex(3)}",
      password: "secret123",
      password_confirmation: "secret123"
    )
  end

  def build_atom_with_audio(user)
    atom = user.atoms.create!(
      title: "Audio atom",
      source: "asset",
      status: AtomConstants::Status::PROCESSING,
      metadata: { "stt_language" => "en-US" }
    )
    atom.assets.create!(
      name: "meeting.mp3",
      format: "audio",
      type: "general",
      source: "upload",
      url: "http://example.test/meeting.mp3",
      storage_key: "test/meeting.mp3",
      size_bytes: 1024
    )
    atom
  end

  def stub_singleton(object, name, impl)
    object.define_singleton_method(name, &impl)
    yield
  ensure
    begin
      object.singleton_class.send(:remove_method, name)
    rescue NameError
      nil
    end
  end

  test "transcribes + summarizes the audio and completes the atom" do
    atom = build_atom_with_audio(build_user)
    stt = lambda do |audio_url:, language: nil|
      { text: "Hello from the meeting", language: language, audio_url: audio_url }
    end
    chat = lambda do |**|
      { "choices" => [ { "message" => { "content" => "## Summary\nKey point." } } ] }
    end

    stub_singleton(SpeechService::Client, :speech_to_text_from_url, stt) do
      stub_singleton(AiService::Client, :chat, chat) do
        Atoms::ProcessAssetContentJob.perform_now(atom.id)
      end
    end

    atom.reload
    assert_equal AtomConstants::Status::COMPLETED, atom.status
    assert_equal "Hello from the meeting", atom.transcript_segments.first["text"]
    assert_includes atom.summary_blocks.first["text"], "Summary"
  end

  test "a provider error schedules a retry instead of losing the atom" do
    atom = build_atom_with_audio(build_user)
    stt = lambda do |audio_url:, language: nil|
      { error: "http_503" }
    end

    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    stub_singleton(SpeechService::Client, :speech_to_text_from_url, stt) do
      Atoms::ProcessAssetContentJob.perform_now(atom.id)
    end

    retried = ActiveJob::Base.queue_adapter.enqueued_jobs.any? do |job|
      job[:job] == Atoms::ProcessAssetContentJob
    end
    assert retried, "expected the job to be rescheduled by the retry policy"
    assert_equal AtomConstants::Status::PROCESSING, atom.reload.status
  end
end
