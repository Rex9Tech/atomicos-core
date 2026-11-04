# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::RunService do
  let(:user) { create(:user) }
  let!(:profile) { Ai::ProfileService.resolve!(AiConstants::ProfileKey::CHAT_DEFAULT) }

  describe ".execute_chat" do
    it "records an Ai::Run and updates telemetry on completion" do
      fake_response = {
        "id" => "run-123",
        "choices" => [ { "message" => { "content" => "Hello from AI!" } } ],
        "usage" => { "prompt_tokens" => 15, "completion_tokens" => 8, "total_tokens" => 23 }
      }
      allow(Ai::Providers::Client).to receive(:chat).and_return(fake_response)

      result = described_class.execute_chat(
        user: user,
        feature: AiConstants::RunFeature::CHAT,
        profile_key: profile.key,
        messages: [ { role: "user", content: "Hi" } ]
      )

      expect(result).to eq(fake_response)

      run = Ai::Run.last
      expect(run.user).to eq(user)
      expect(run.profile).to eq(profile)
      expect(run.status).to eq(AiConstants::RunStatus::COMPLETED)
      expect(run.output_chars).to eq("Hello from AI!".length)
      expect(run.prompt_tokens).to eq(15)
      expect(run.completion_tokens).to eq(8)
      expect(run.total_tokens).to eq(23)
      expect(run.latency_ms).to be >= 0
    end

    it "records failure telemetry when LLM returns error" do
      allow(Ai::Providers::Client).to receive(:chat).and_return({ error: "API rate limit exceeded" })

      described_class.execute_chat(
        user: user,
        feature: AiConstants::RunFeature::CHAT,
        profile_key: profile.key,
        messages: [ { role: "user", content: "Hi" } ]
      )

      run = Ai::Run.last
      expect(run.status).to eq(AiConstants::RunStatus::FAILED)
      expect(run.error).to eq("API rate limit exceeded")
    end
  end

  describe ".list" do
    it "filters runs by feature, status, and user" do
      run1 = create(:ai_run, user: user, feature: AiConstants::RunFeature::CHAT, status: AiConstants::RunStatus::COMPLETED)
      run2 = create(:ai_run, user: user, feature: AiConstants::RunFeature::SUMMARIZE, status: AiConstants::RunStatus::FAILED)

      expect(described_class.list(feature: AiConstants::RunFeature::CHAT)).to include(run1)
      expect(described_class.list(feature: AiConstants::RunFeature::CHAT)).not_to include(run2)
      expect(described_class.list(status: AiConstants::RunStatus::FAILED)).to include(run2)
    end
  end

  describe ".start_transcribe / .finish_transcribe" do
    it "records a profile-less transcribe run and prices it by audio duration" do
      stub_const("AppConfig::GEMINI_LIVE_AUDIO_USD_PER_MINUTE", 0.0015)

      run = described_class.start_transcribe(
        user: user,
        provider: AiConstants::Provider::GEMINI,
        model: AppConfig::GEMINI_LIVE_MODEL,
        request_metadata: { "endpoint" => "speech_live", "language" => "my-MM" }
      )

      expect(run.feature).to eq(AiConstants::RunFeature::TRANSCRIBE)
      expect(run.profile).to be_nil
      expect(run.status).to eq(AiConstants::RunStatus::PROCESSING)

      described_class.finish_transcribe(run, audio_seconds: 90.0, transcript_chars: 120, latency_ms: 95_000)

      run.reload
      expect(run.status).to eq(AiConstants::RunStatus::COMPLETED)
      expect(run.output_chars).to eq(120)
      expect(run.latency_ms).to eq(95_000)
      expect(run.request_metadata["audio_seconds"]).to eq(90.0)
      expect(run.cost_usd).to be_within(0.000001).of(0.00225)
    end

    it "leaves cost empty for non-Gemini live providers (no rate configured)" do
      run = described_class.start_transcribe(user: user, provider: AiConstants::Provider::AZURE, model: "azure-speech")

      described_class.finish_transcribe(run, audio_seconds: 60.0)

      run.reload
      expect(run.status).to eq(AiConstants::RunStatus::COMPLETED)
      expect(run.cost_usd).to be_nil
    end

    it "records errors onto the run" do
      run = described_class.start_transcribe(user: user, provider: AiConstants::Provider::GEMINI, model: AppConfig::GEMINI_LIVE_MODEL)

      described_class.finish_transcribe(run, audio_seconds: 12.5, error: "provider exploded")

      run.reload
      expect(run.status).to eq(AiConstants::RunStatus::FAILED)
      expect(run.error).to eq("provider exploded")
    end
  end
end
