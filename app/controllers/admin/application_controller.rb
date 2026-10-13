# All Administrate controllers inherit from this controller.
#
# AtomicOS Admin uses session-based sign-in (Admin::SessionsController) with a
# Basic-auth fallback for CLI/curl use, replacing the raw HTTP Basic popup.
module Admin
  class ApplicationController < Administrate::ApplicationController
    before_action :authenticate_admin
    before_action :touch_admin_session

    helper_method :current_admin_user, :admin_signed_in?

    # Overrides Administrate's default (which derives from the app module name).
    def application_title
      "AtomicOS"
    end
    helper_method :application_title

    # Kept for backwards compatibility with admin views/code that reference
    # `current_user` — in the admin console it maps to the admin user.
    def current_user
      current_admin_user
    end

    private

    def authenticate_admin
      return if current_admin_user.present?

      # Basic-auth fallback (CLI/curl): only attempted when an Authorization
      # header is present so browsers get the branded sign-in form instead of
      # the native browser popup.
      if request.authorization.present?
        username, password = ActionController::HttpAuthentication::Basic.user_name_and_password(request)
        user = AdminAuthService.authenticate(username: username, password: password, ip: request.remote_ip)

        if user
          @current_admin_user = user
          session[:admin_user_id] = user.id
          session[:admin_last_seen] = Time.current.to_i
          return
        end

        return head :unauthorized
      end

      redirect_to admin_signin_path
    end

    def touch_admin_session
      session[:admin_last_seen] = Time.current.to_i if @current_admin_user.present?
    end

    def current_admin_user
      @current_admin_user ||= begin
        id = session[:admin_user_id]
        user = id && User.find_by(id: id)

        if user&.admin? && session[:admin_last_seen].to_i > 12.hours.ago.to_i
          user
        else
          session.delete(:admin_user_id)
          session.delete(:admin_last_seen)
          nil
        end
      end
    end

    def admin_signed_in?
      current_admin_user.present?
    end
  end
end
