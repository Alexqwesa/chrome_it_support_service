FROM dart:stable AS build
WORKDIR /app
COPY pubspec.yaml pubspec.lock analysis_options.yaml ./
RUN dart pub get
COPY .env.example ./
COPY bin ./bin
COPY lib ./lib
RUN dart compile exe bin/server.dart -o /app/debug_relay_server

FROM debian:bookworm-slim
RUN useradd --system --uid 10001 --no-create-home relay
COPY --from=build /runtime/etc/ /etc/
COPY --from=build /runtime/lib/ /lib/
COPY --from=build /runtime/lib64/ /lib64/
COPY --from=build /runtime/usr/ /usr/
COPY --from=build /app/debug_relay_server /usr/local/bin/debug_relay_server
USER relay
EXPOSE 9998 41000-41049
ENTRYPOINT ["/usr/local/bin/debug_relay_server"]
