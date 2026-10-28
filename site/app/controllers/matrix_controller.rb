class MatrixController < ApplicationController
  # Group by build, release, or model and stack; the model summary keeps its build history available.
  def show
    @filter = ReportFilter.new(params)
    @group = params[:group].presence_in(%w[build release model]) || "model"
    @by_build = @group == "build"
    @by_model = @group == "model"
    reports = Report.visible.to_a
    @matrix = CompatibilityMatrix.visible(by_build: @by_build, by_model: @by_model, filter: @filter, reports:)
    if @by_model
      # Result filters narrow summaries; history keeps all matching runs as evidence.
      history_filter = ReportFilter.new(@filter.values, keys: ReportFilter::RUN_KEYS)
      @history = CompatibilityMatrix.visible(filter: history_filter, reports:).rows.group_by { |row| [ row.configuration.board, row.configuration.stack ] }
    end
    @options = FilterOptions.new(reports)
  end
end
