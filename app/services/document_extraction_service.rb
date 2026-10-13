# frozen_string_literal: true

# Best-effort text extraction for uploaded documents so the AI can actually
# read attachments (PDF via poppler's pdftotext, DOCX via unzip, plain text
# formats read directly). Runs at upload time while the raw bytes are still
# available on the request's tempfile. Never raises — failures return nil.
class DocumentExtractionService
  MAX_CHARS = 12_000
  READ_BYTES = 400_000

  PLAIN_TEXT_EXTENSIONS = %w[
    txt text md markdown csv tsv json xml log yml yaml ini cfg conf
  ].freeze

  # file       — ActionDispatch::Http::UploadedFile (or anything with tempfile/path)
  # extension  — downcased original extension, e.g. "pdf"
  # content_type — the upload's content type, e.g. "text/plain"
  def self.extract(file:, extension:, content_type: nil)
    path = file_path(file)
    return nil if path.blank? || !File.exist?(path)

    ext = extension.to_s.downcase
    text =
      case ext
      when "pdf" then extract_pdf(path)
      when "docx" then extract_docx(path)
      else
        if PLAIN_TEXT_EXTENSIONS.include?(ext) ||
           content_type.to_s.downcase.start_with?("text/")
          read_text(path)
        end
      end

    return nil if text.blank?

    cleaned = text.force_encoding("UTF-8").scrub(" ")
    cleaned = cleaned.gsub(/[ \t]+\n/, "\n").gsub(/\n{3,}/, "\n\n").strip
    return nil if cleaned.blank?

    cleaned.truncate(MAX_CHARS, omission: "…")
  rescue StandardError => e
    Rails.logger.warn("[DocumentExtraction] #{e.class}: #{e.message}")
    nil
  end

  def self.file_path(file)
    if file.respond_to?(:tempfile) && file.tempfile
      file.tempfile.path
    elsif file.respond_to?(:path)
      file.path
    end
  end
  private_class_method :file_path

  def self.extract_pdf(path)
    return nil unless binary_available?("pdftotext")

    out = nil
    IO.popen([ "pdftotext", "-q", "-layout", path, "-" ], err: File::NULL) do |io|
      out = io.read
    end
    out.presence
  end
  private_class_method :extract_pdf

  # DOCX is a zip; pull word/document.xml and strip the markup.
  def self.extract_docx(path)
    return nil unless binary_available?("unzip")

    xml = nil
    IO.popen([ "unzip", "-p", path, "word/document.xml" ], err: File::NULL) do |io|
      xml = io.read
    end
    return nil if xml.blank?

    xml
      .gsub(%r{</w:p>}, "\n")
      .gsub(%r{<w:br\s*/?>}, "\n")
      .gsub(%r{<[^>]+>}, "")
      .gsub("&amp;", "&").gsub("&lt;", "<").gsub("&gt;", ">")
      .gsub("&quot;", '"').gsub("&apos;", "'")
      .presence
  end
  private_class_method :extract_docx

  def self.read_text(path)
    File.binread(path, READ_BYTES).to_s
  end
  private_class_method :read_text

  def self.binary_available?(name)
    @binary_cache ||= {}
    return @binary_cache[name] unless @binary_cache[name].nil?

    @binary_cache[name] = system("which #{name} > /dev/null 2>&1") || false
  end
  private_class_method :binary_available?
end
