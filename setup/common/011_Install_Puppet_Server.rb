test_name "Install Puppet Server" do
  skip_test "not testing with puppetserver" unless @options['is_puppetserver']

  install_puppetserver_on(master,
                          version: ENV['SERVER_VERSION'] || 'latest',
                          release_stream: ENV['RELEASE_STREAM'] || 'puppet',
                          dev_builds_url: ENV['DEV_BUILDS_URL'],
                          nightly_builds_url: ENV['NIGHTLY_BUILDS_URL'],
                          nightlies: true)
end
