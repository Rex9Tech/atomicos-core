# frozen_string_literal: true

# app/services/content_fetch_service.rb
# Fetches a public URL and extracts readable metadata + text for AI processing.
module ContentFetchService
  module_function

  USER_AGENT = "AtomicOSBot/1.0 (+https://atomicos)".freeze
  MAX_BYTES = 1_000_000
  MAX_REDIRECTS = 5

  Result = Struct.new(:title, :description, :text, :error, keyword_init: true)

  def fetch(url)
    uri = parse_uri(url)
    return Result.new(error: "invalid_url") unless uri

    html = fetch_html(uri)
    return Result.new(error: "unreachable") if html.blank?

    Result.new(
      title: extract_title(html),
      description: extract_description(html),
      text: extract_text(html),
      error: nil
    )
  rescue StandardError => e
    Result.new(error: e.message)
  end

  def parse_uri(url)
    uri = URI.parse(url.to_s.strip)
    (uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)) ? uri : nil
  rescue URI::InvalidURIError
    nil
  end

  def fetch_html(uri, redirects = 0)
    return "" if redirects > MAX_REDIRECTS

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 15

    request = Net::HTTP::Get.new(uri.request_uri)
    request["User-Agent"] = USER_AGENT
    request["Accept"] = "text/html,application/xhtml+xml"

    response = http.request(request)

    case response
    when Net::HTTPSuccess
      response.body.to_s.byteslice(0, MAX_BYTES).to_s
    when Net::HTTPRedirection
      location = response["location"].to_s
      return "" if location.blank?
      next_uri = resolve_redirect(uri, location)
      next_uri ? fetch_html(next_uri, redirects + 1) : ""
    else
      ""
    end
  end

  def resolve_redirect(uri, location)
    if location.start_with?("http://", "https://")
      parse_uri(location)
    else
      parse_uri("#{uri.scheme}://#{uri.host}#{location}")
    end
  end

  def extract_title(html)
    og = meta_content(html, "og:title")
    return og if og.present?

    title = html[/<title[^>]*>(.*?)<\/title>/im, 1]
    CGI.unescapeHTML(title.to_s).strip
  end

  def extract_description(html)
    meta_content(html, "og:description").presence ||
      meta_content(html, "description")
  end

  def meta_content(html, key)
    value =
      html[/<meta[^>]*property=["']#{Regexp.escape(key)}["'][^>]*content=["']([^"']*)["']/i, 1] ||
      html[/<meta[^>]*name=["']#{Regexp.escape(key)}["'][^>]*content=["']([^"']*)["']/i, 1] ||
      html[/<meta[^>]*content=["']([^"']*)["'][^>]*property=["']#{Regexp.escape(key)}["']/i, 1] ||
      html[/<meta[^>]*content=["']([^"']*)["'][^>]*name=["']#{Regexp.escape(key)}["']/i, 1]
    CGI.unescapeHTML(value.to_s).strip
  end

  def extract_text(html)
    body = html.sub(/.*?<body[^>]*>/im, "").sub(/<\/body>.*/im, "")
    body = body.gsub(/<(script|style|noscript|iframe|svg|head)[^>]*>.*?<\/\1>/im, " ")
               .gsub(/<[^>]+>/, " ")
    text = CGI.unescapeHTML(body)
    text.gsub(/[ \t]+/, " ").gsub(/\n\s*\n+/, "\n").strip
  end
end
