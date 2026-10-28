# A Mac model (board) on an Omarchy stack, release and build: one row of the
# matrix. build is the Build's words and build_id its runtime build id, both
# nil for a reference run or when the builds of a release are merged.
Configuration = Data.define(:board, :stack, :version, :build, :build_id) do
  def initialize(board:, stack:, version:, build: nil, build_id: nil) = super

  def stack_words = Report::STACK_WORDS.fetch(stack, stack)
  def release_label = version ? "#{stack_words} #{version}" : "#{stack_words} · latest results"
  def label = build ? "#{release_label} · build #{build}" : release_label
end
