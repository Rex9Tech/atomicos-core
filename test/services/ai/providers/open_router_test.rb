# frozen_string_literal: true

require "test_helper"

module Ai
  module Providers
    class OpenRouterTest < ActiveSupport::TestCase
      test "openrouter is a registered provider" do
        assert_includes AiConstants::Provider::ALL, "openrouter"
      end

      test "client dispatches openrouter to the OpenRouter provider" do
        provider = Ai::Providers::Client.for_provider("openrouter")
        assert_instance_of Ai::Providers::OpenRouter, provider
      end

      test "default_model_for maps openrouter to the configured OpenRouter model" do
        assert_equal AppConfig::OPENROUTER_MODEL,
                     Ai::ProfileService.send(:default_model_for, AiConstants::Provider::OPENROUTER)
      end

      test "default_provider is always a registered provider" do
        assert_includes AiConstants::Provider::ALL, Ai::ProfileService.send(:default_provider)
      end
    end
  end
end
