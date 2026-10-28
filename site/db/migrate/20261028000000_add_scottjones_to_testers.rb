# Adds scottjones to the tester allowlist. His Macs (an M3 MacBook Air and the
# MacBook Neo) are already signed in as him, so their runs uploaded since
# sign-in count as tester runs at once. Skipped if the admin added him already;
# the GitHub account is pinned at his next sign-in, as with every handle.
class AddScottjonesToTesters < ActiveRecord::Migration[8.1]
  LOGIN = "scottjones"

  def up
    now = connection.quote(Time.current.utc)
    execute "INSERT INTO testers (login, created_at, updated_at) VALUES (#{connection.quote(LOGIN)}, #{now}, #{now}) ON CONFLICT (login) DO NOTHING"
  end

  # Leaves the handle: the admin may have added it by hand. Remove it at /admin/testers.
  def down; end
end
