# The choices the filter bar offers (ReportFilter), from the visible runs:
# each a list of [value, words], newest or in the catalogue's order.
class FilterOptions
  def initialize(reports, filter: nil)
    @reports = reports
    @filter = filter
  end

  def build
    reports = @filter ? ReportFilter.new(@filter.values.except("build")).runs(@reports) : @reports
    builds = Build.runs(reports)
    labels = builds.map { |build, _| build.label }.tally
    builds.map do |build, runs|
      # Variants of one runtime need their kernel/image details in the picker.
      label = labels.fetch(build.label) > 1 ? build.words : build.label
      [ build.words, "#{label} (#{runs.size})" ]
    end.uniq(&:first)
  end
  def set = values { |report| report.build&.set }.sort.reverse.map { |name| [ name, name ] }
  def release = versions(values(&:omarchy_version))
  # Kernel releases contain distro suffixes; compare numeric parts as numbers.
  def kernel
    values(&:kernel).sort_by do |version|
      version.split(/(\d+)/).map { |part| part.match?(/\A\d+\z/) ? [ 1, part.to_i ] : [ 0, part ] }
    end.reverse.map { |version| [ version, version ] }
  end

  def stack = CompatibilityMatrix::STACKS.map { |stack| [ stack, Report::STACK_WORDS.fetch(stack) ] }
  def model = @reports.map { |report| [ report.board, "#{report.short_model_name} (#{report.board})" ] }.uniq(&:first).sort_by(&:last)
  def gen = (ReportFilter.generations & values { |report| Catalogue.chip_for_soc(report.soc)&.split("-")&.first }).map { |gen| [ gen, gen.upcase ] }
  def chip = values(&:chip).sort.map { |chip| [ chip, chip ] }
  def soc = values(&:soc).sort.map { |soc| [ soc, soc ] }
  def runs = [ [ "tester", "tester runs only" ], [ "community", "community runs only" ] ]
  def tool = versions(values(&:tool_version))
  def layer = Catalogue::LAYERS.map { |layer| [ layer, Catalogue::LAYER_WORDS.fetch(layer) ] }
  def state = ReportFilter::STATE_WORDS.to_a

  private

  def values(&block) = @reports.filter_map(&block).uniq

  def versions(list)
    list.sort_by { |version| Gem::Version.correct?(version) ? Gem::Version.new(version) : Gem::Version.new("0") }.reverse.map { |v| [ v, v ] }
  end
end
