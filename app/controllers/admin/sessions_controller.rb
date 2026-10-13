# frozen_string_literal: true

module Admin
  # Standalone session-based sign-in for the admin console (AtomicOS Admin).
  #
  # Replaces the raw HTTP Basic browser popup with a branded login form while
  # keeping exactly the same credential checks (AdminAuthService) and the same
  # attempt limiting / IP lockout behavior.
  class SessionsController < ActionController::Base
    layout "admin_login"

    # GET /admin/signin
    def new
      return redirect_to admin_root_path if signed_in_admin.present?

      @username = ""
    end

    # POST /admin/signin
    def create
      user = AdminAuthService.authenticate(
        username: params[:username].to_s,
        password: params[:password].to_s.strip,
        ip: request.remote_ip
      )

      if user
        reset_session
        session[:admin_user_id] = user.id
        session[:admin_last_seen] = Time.current.to_i
        redirect_to admin_root_path
      else
        flash.now[:alert] = failure_message
        @username = params[:username].to_s
        render :new, status: :unprocessable_content
      end
    end

    # GET /admin/signout
    def destroy
      reset_session
      redirect_to admin_signin_path
    end

    private

    def signed_in_admin
      id = session[:admin_user_id]
      user = id && User.find_by(id: id)
      user if user&.admin?
    end

    def failure_message
      name = params[:username].to_s.strip.downcase
      user = name.present? ? User.find_by("LOWER(username) = ?", name) : nil

      if user&.admin?
        remaining = PasswordService.new(user.id).cooldown_remaining
        return "Too many attempts. Try again in #{remaining} seconds." if remaining.positive?
      end

      "Invalid username or password."
    end
  end
end
