FROM ruby:3.3-slim

ENV LANG=C.UTF-8 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    KOPYA_MOD=sunucu \
    KOPYA_ACMA=0

WORKDIR /app

# Nokogiri için derleme araçları; gem kurulduktan sonra imajı küçültmek üzere silinir
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential libxml2-dev libxslt1-dev && \
    rm -rf /var/lib/apt/lists/*

COPY Gemfile ./
RUN bundle install && \
    apt-get purge -y --auto-remove build-essential libxml2-dev libxslt1-dev && \
    rm -rf /var/lib/apt/lists/*

COPY kopya_sunucu.rb site_kopyala.rb ./

EXPOSE 8080
CMD ["ruby", "kopya_sunucu.rb"]
