class AddCostUsdToAiRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :ai_runs, :cost_usd, :decimal, precision: 12, scale: 6, if_not_exists: true
  end
end
