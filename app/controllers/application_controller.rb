# app/controllers/application_controller.rb
class ApplicationController < ActionController::API
  AUTH_LOG_PREFIX = "[Auth]".freeze
  SUPPORTED_LOCALES = %w[en my].freeze

  include Pagy::Method
  include Authorization
  include ApplicationHelper
  include PagyHelper
  include SortableHelper
  include PlatformSession

  around_action :switch_locale
  before_action :enforce_active_platform_session!, :set_current_auditor
  before_action :authenticate_user!

  private

  def switch_locale(&action)
    I18n.with_locale(requested_locale, &action)
  end

  def requested_locale
    candidates = [
      params.permit(:locale)[:locale],
      request.headers[AuthConstants::Headers::LOCALE],
      *request.headers[AuthConstants::Headers::ACCEPT_LANGUAGE].to_s.split(",")
    ]

    candidates.each do |candidate|
      locale = candidate.to_s.split(";").first.to_s.strip.downcase.split(/[-_]/).first
      return locale if SUPPORTED_LOCALES.include?(locale)
    end

    I18n.default_locale
  end

  def set_current_auditor
    Current.auditor = current_user if current_user
  end

  def enforce_active_platform_session!
    return unless current_user

    bearer_token = request.headers[AuthConstants::Headers::AUTHORIZATION].to_s.split(" ").last
    return if bearer_token.blank?

    key = session_key(current_user.id)
    active_token = CacheService.read(key)

    # Graceful fallback for clients that cannot send X-Platform (e.g. native
    # background upload workers): their request resolves to 'web' by default,
    # but the token may be the active session of another platform
    # (android/ios). Accept whenever the token EXACTLY matches any platform's
    # stored token, and refresh that key instead. A superseded token never
    # matches (keys only ever hold the latest token per platform), so
    # single-active-session enforcement is preserved.
    if active_token.blank? || active_token != bearer_token
      fallback_key = AuthConstants::Platform::ALL.map { |platform|
        AuthConstants::Session.key(current_user.id, platform)
      }.find do |candidate|
        candidate != key && CacheService.read(candidate) == bearer_token
      end

      if fallback_key.present?
        key = fallback_key
        active_token = bearer_token
      end
    end

    if active_token.blank? || active_token != bearer_token
      render_json_response(
        status_code: 401,
        message: auth_message(MessageService::Auth::SIGN_IN_FAILED),
        error: auth_message(MessageService::Auth::ACTIVE_SESSION_NOT_FOUND)
      )
      return
    end

    # Refresh the session TTL on each request
    CacheService.write(key, bearer_token, expires_in: AppConfig::SESSION_TIMEOUT)
  rescue => e
    Rails.logger.error(
      "#{AUTH_LOG_PREFIX} Active session verification failed: #{e.message}"
    )
  end

  def auth_message(key, **options)
    MessageService::Auth.t(key, **options)
  end

  def session_key(user_id)
    AuthConstants::Session.key(user_id, platform_session)
  end
end
