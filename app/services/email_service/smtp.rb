# app/services/email_service/smtp.rb
require "erb"

module EmailService
  # SMTP delivery provider (self-hosted Postfix / any SMTP relay).
  # Delivers through Rails ActionMailer using the SMTP_* settings
  # configured in config/environments/production.rb.
  class Smtp < Base
    LOG_PREFIX = "[SMTP]".freeze

    def initialize
      @address = AppConfig::SMTP_ADDRESS
      @port = AppConfig::SMTP_PORT

      if @address.blank?
        Rails.logger.info("#{LOG_PREFIX} not configured - email delivery disabled")
        @disabled = true
      end
    end

    def send_email(to:, subject:, body:, from: nil, reply_to: nil, **kwargs)
      return { "disabled" => true } if @disabled

      rendered_body = render_body(subject: subject, body: body, kwargs: kwargs)

      message = ActionMailer::Base.mail(
        to: to,
        from: from.presence || AppConfig::FROM_EMAIL,
        reply_to: reply_to.presence,
        subject: subject.to_s,
        body: rendered_body,
        content_type: "text/html"
      )
      message.deliver_now
      { "delivered" => true, "provider" => "smtp" }
    rescue StandardError => e
      Rails.logger.error("#{LOG_PREFIX} Email failed: #{e.message}")
      raise EmailService::Error, "Failed to send email: #{e.message}"
    end

    def send_template(to:, template_id:, template_data: {}, from: nil)
      return { "disabled" => true } if @disabled

      # 1. Prefer local TemplateRenderer if template exists in catalog
      rendered_body = TemplateRenderer.render(template_id, template_data)
      if rendered_body.present?
        subject = TemplateRenderer.subject(template_id, template_data).presence ||
                  fallback_subject(template_id, template_data)
        return send_email(
          to: to,
          subject: subject,
          body: rendered_body,
          from: from
        )
      end

      # 2. Ad-hoc fallback
      send_email(
        to: to,
        subject: fallback_subject(template_id, template_data),
        body: fallback_body(template_id, template_data),
        from: from
      )
    end

    private

    def render_body(subject:, body:, kwargs:)
      return body if body.to_s.strip.start_with?("<")

      data = (kwargs[:data] || kwargs).with_indifferent_access
      TemplateRenderer.render_content(
        title: subject,
        body: body,
        cta_url: data[:cta_url] || data[:link] || kwargs[:link],
        cta_text: data[:cta_text],
        highlight: data[:highlight] || data[:code] || data[:promo_code],
        details: data[:details],
        disclaimer: data[:disclaimer],
        data: data
      )
    end

    def fallback_subject(template_id, data)
      TemplateRenderer.subject(template_id, data).presence ||
        template_id.to_s.tr("_", " ").titleize.presence ||
        MessageService::Notification.t(MessageService::Notification::DEFAULT_TITLE)
    end

    def fallback_body(template_id, data)
      rendered_template = TemplateRenderer.render(template_id, data)
      return rendered_template if rendered_template.present?

      body_content = data[:body].presence || data[:message].presence
      if body_content.present?
        return TemplateRenderer.render_content(
          title: fallback_subject(template_id, data),
          body: body_content,
          data: data
        )
      end

      rows = data.map do |key, value|
        "<p><strong>#{ERB::Util.html_escape(key.to_s.humanize)}:</strong> #{ERB::Util.html_escape(value.to_s)}</p>"
      end.join

      rows.presence ||
        "<p>#{ERB::Util.html_escape(fallback_subject(template_id, data))}</p>"
    end
  end
end
