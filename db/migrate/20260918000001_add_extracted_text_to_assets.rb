# frozen_string_literal: true

# Stores best-effort extracted document text on assets (PDF / DOCX / plain
# text) so the AI can actually read attached documents as context.
class AddExtractedTextToAssets < ActiveRecord::Migration[8.0]
  def change
    add_column :assets, :extracted_text, :text
  end
end
