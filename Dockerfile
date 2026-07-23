# Reproducible build using the official Ruby image.
# Replaces the Nixpacks/rbenv flow, which installed Ruby by fetching
# github.com/rbenv/rbenv-installer/raw/HEAD at build time — an unpinned
# external script that started failing intermittently and broke deploys.
# The official image ships Ruby 3.2 pre-installed, so no rbenv/github fetch.
FROM ruby:3.2-slim

WORKDIR /app

# Install gems first so this layer is cached unless the Gemfile changes.
# Pin bundler to the version in Gemfile.lock (BUNDLED WITH) to avoid any
# bundler-version mismatch; rubygems.org is reliable (unlike the old rbenv fetch).
COPY Gemfile Gemfile.lock ./
RUN gem install bundler:2.5.6 && bundle install --jobs 4 --retry 3

# App source.
COPY . .

# Railway injects PORT; server.rb reads ENV['PORT'] (defaults to 8080).
EXPOSE 8080

CMD ["bundle", "exec", "ruby", "server.rb"]
