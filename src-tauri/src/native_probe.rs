use crate::{error::CommandError, soundcloud::is_playback_cdn_url};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use reqwest::{blocking::Client, header};
use serde_json::{Value, json};
use std::{
    fs::{self, File},
    io::{BufRead, BufReader},
    path::PathBuf,
    process::{Child, Command},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread::JoinHandle,
    time::Duration,
};
use tauri::{AppHandle, Emitter, Manager};
use tiny_http::{Header, Request, Response, Server, StatusCode};
use url::Url;
use uuid::Uuid;

pub const EVENT_NAME: &str = "native-audio-probe";

pub struct NativeProbe {
    runtime: Mutex<Option<ProbeRuntime>>,
}

struct ProbeRuntime {
    launcher: Child,
    proxy: PlaybackProxy,
    files: ProbeFiles,
    relay_stop: Arc<AtomicBool>,
    relay_threads: Vec<JoinHandle<()>>,
}

struct ProbeFiles {
    directory: PathBuf,
    input: PathBuf,
    output: PathBuf,
    errors: PathBuf,
    stop: PathBuf,
}

struct PlaybackProxy {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    playback_url: String,
}

impl NativeProbe {
    pub fn new() -> Self {
        Self {
            runtime: Mutex::new(None),
        }
    }

    pub fn start(&self, app: &AppHandle, playback_url: &str) -> Result<(), CommandError> {
        self.stop()?;

        #[cfg(not(target_os = "macos"))]
        {
            let _ = (app, playback_url);
            return Err(CommandError::new(
                "native_probe_unavailable",
                "The native audio probe is available only on macOS.",
            ));
        }

        #[cfg(target_os = "macos")]
        {
            let bundle = bundle_path(app)?;
            let proxy = PlaybackProxy::start(playback_url)?;
            let files = ProbeFiles::create(app, &proxy.playback_url)?;
            let launcher = Command::new("/usr/bin/open")
                .arg("-n")
                .arg("-g")
                .arg("-W")
                .arg("-i")
                .arg(&files.input)
                .arg("-o")
                .arg(&files.output)
                .arg("--stderr")
                .arg(&files.errors)
                .arg(&bundle)
                .arg("--args")
                .arg("--stop-file")
                .arg(&files.stop)
                .spawn()
                .map_err(|_| {
                    CommandError::new(
                        "native_probe_start_failed",
                        format!(
                            "The native audio probe could not start. Build it with {}.",
                            build_script_path().display()
                        ),
                    )
                })?;

            let relay_stop = Arc::new(AtomicBool::new(false));
            let relay_threads = relay_output(app, &files, relay_stop.clone());
            *self.runtime.lock().map_err(|_| probe_state_error())? = Some(ProbeRuntime {
                launcher,
                proxy,
                files,
                relay_stop,
                relay_threads,
            });
            Ok(())
        }
    }

    pub fn stop(&self) -> Result<(), CommandError> {
        let Some(runtime) = self.runtime.lock().map_err(|_| probe_state_error())?.take() else {
            return Ok(());
        };
        runtime.stop();
        Ok(())
    }
}

impl Drop for NativeProbe {
    fn drop(&mut self) {
        if let Ok(runtime) = self.runtime.get_mut()
            && let Some(runtime) = runtime.take()
        {
            runtime.stop();
        }
    }
}

impl ProbeRuntime {
    fn stop(mut self) {
        let _ = fs::remove_file(&self.files.stop);
        for _ in 0..40 {
            if self.launcher.try_wait().ok().flatten().is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        if self.launcher.try_wait().ok().flatten().is_none() {
            let _ = self.launcher.kill();
        }
        let _ = self.launcher.wait();
        self.relay_stop.store(true, Ordering::Release);
        for thread in self.relay_threads {
            let _ = thread.join();
        }
        self.proxy.stop();
        self.files.remove();
    }
}

impl ProbeFiles {
    fn create(app: &AppHandle, playback_url: &str) -> Result<Self, CommandError> {
        let directory = app
            .path()
            .app_cache_dir()
            .map_err(|_| probe_files_error())?
            .join("native-audio-probe")
            .join(Uuid::new_v4().simple().to_string());
        fs::create_dir_all(&directory).map_err(|_| probe_files_error())?;

        let files = Self {
            input: directory.join("input.json"),
            output: directory.join("output.ndjson"),
            errors: directory.join("errors.log"),
            stop: directory.join("running"),
            directory,
        };
        let input = serde_json::to_string(&json!({ "url": playback_url }))
            .map_err(|_| probe_files_error())?;
        fs::write(&files.input, format!("{input}\n")).map_err(|_| probe_files_error())?;
        File::create(&files.output).map_err(|_| probe_files_error())?;
        File::create(&files.errors).map_err(|_| probe_files_error())?;
        File::create(&files.stop).map_err(|_| probe_files_error())?;
        Ok(files)
    }

    fn remove(&self) {
        for path in [&self.input, &self.output, &self.errors, &self.stop] {
            let _ = fs::remove_file(path);
        }
        let _ = fs::remove_dir(&self.directory);
    }
}

impl PlaybackProxy {
    fn start(playback_url: &str) -> Result<Self, CommandError> {
        let source = parse_cdn_url(playback_url)?;
        let server = Server::http("127.0.0.1:0").map_err(|_| {
            CommandError::new(
                "native_probe_proxy_failed",
                "The local playback proxy could not start.",
            )
        })?;
        let address = server.server_addr().to_ip().ok_or_else(|| {
            CommandError::new(
                "native_probe_proxy_failed",
                "The local playback proxy did not return an IP address.",
            )
        })?;
        let route_secret = Uuid::new_v4().simple().to_string();
        let encoded_source = URL_SAFE_NO_PAD.encode(source.as_str());
        let local_url = format!("http://{address}/{route_secret}/{encoded_source}");
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let thread = std::thread::spawn(move || {
            run_proxy(server, &route_secret, thread_stop);
        });

        Ok(Self {
            stop,
            thread: Some(thread),
            playback_url: local_url,
        })
    }

    fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for PlaybackProxy {
    fn drop(&mut self) {
        self.stop();
    }
}

fn run_proxy(server: Server, route_secret: &str, stop: Arc<AtomicBool>) {
    let client = match Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(30))
        .build()
    {
        Ok(client) => client,
        Err(_) => return,
    };

    while !stop.load(Ordering::Acquire) {
        let Ok(request) = server.recv_timeout(Duration::from_millis(100)) else {
            continue;
        };
        let Some(request) = request else { continue };
        proxy_request(request, &client, route_secret);
    }
}

fn proxy_request(request: Request, client: &Client, route_secret: &str) {
    if request.method().as_str() != "GET" {
        respond_text(request, 405, "Only GET is supported.");
        return;
    }

    let request_path = request.url().split('?').next().unwrap_or(request.url());
    let expected_prefix = format!("/{route_secret}/");
    let Some(encoded_url) = request_path.strip_prefix(&expected_prefix) else {
        respond_text(request, 404, "Not found.");
        return;
    };
    let Ok(decoded_url) = URL_SAFE_NO_PAD.decode(encoded_url) else {
        respond_text(request, 400, "Invalid playback URL.");
        return;
    };
    let Ok(decoded_url) = String::from_utf8(decoded_url) else {
        respond_text(request, 400, "Invalid playback URL.");
        return;
    };
    let Ok(target) = parse_cdn_url(&decoded_url) else {
        respond_text(request, 403, "Playback host is not allowed.");
        return;
    };

    let mut outbound = client.get(target.clone());
    if let Some(range) = request
        .headers()
        .iter()
        .find(|value| value.field.equiv("Range"))
    {
        outbound = outbound.header(header::RANGE, range.value.as_str());
    }
    let Ok(response) = outbound.send() else {
        respond_text(request, 502, "The playback request failed.");
        return;
    };

    let status = response.status();
    if !status.is_success() {
        respond_text(
            request,
            status.as_u16(),
            "The playback server rejected the request.",
        );
        return;
    }

    let content_type = response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let content_range = response
        .headers()
        .get(header::CONTENT_RANGE)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let accept_ranges = response
        .headers()
        .get(header::ACCEPT_RANGES)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let Ok(bytes) = response.bytes() else {
        respond_text(request, 502, "The playback response could not be read.");
        return;
    };

    let is_playlist = content_type
        .as_deref()
        .is_some_and(|value| value.contains("mpegurl"))
        || bytes.starts_with(b"#EXTM3U");
    let body = if is_playlist {
        let Ok(playlist) = std::str::from_utf8(&bytes) else {
            respond_text(request, 502, "The HLS playlist is invalid.");
            return;
        };
        rewrite_playlist(playlist, &target, route_secret).into_bytes()
    } else {
        bytes.to_vec()
    };

    let mut proxied = Response::from_data(body).with_status_code(StatusCode(status.as_u16()));
    add_response_header(
        &mut proxied,
        "Content-Type",
        content_type
            .as_deref()
            .unwrap_or("application/octet-stream"),
    );
    if let Some(value) = content_range {
        add_response_header(&mut proxied, "Content-Range", &value);
    }
    if let Some(value) = accept_ranges {
        add_response_header(&mut proxied, "Accept-Ranges", &value);
    }
    let _ = request.respond(proxied);
}

fn rewrite_playlist(playlist: &str, base_url: &Url, route_secret: &str) -> String {
    playlist
        .lines()
        .map(|line| {
            if line.starts_with('#') {
                rewrite_uri_attributes(line, base_url, route_secret)
            } else if line.trim().is_empty() {
                String::new()
            } else {
                proxy_url(line.trim(), base_url, route_secret).unwrap_or_else(|| line.to_owned())
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}

fn rewrite_uri_attributes(line: &str, base_url: &Url, route_secret: &str) -> String {
    let mut result = line.to_owned();
    let mut search_from = 0;
    while let Some(relative_start) = result[search_from..].find("URI=\"") {
        let value_start = search_from + relative_start + 5;
        let Some(relative_end) = result[value_start..].find('"') else {
            break;
        };
        let value_end = value_start + relative_end;
        let original = &result[value_start..value_end];
        let Some(replacement) = proxy_url(original, base_url, route_secret) else {
            break;
        };
        result.replace_range(value_start..value_end, &replacement);
        search_from = value_start + replacement.len();
    }
    result
}

fn proxy_url(value: &str, base_url: &Url, route_secret: &str) -> Option<String> {
    let target = base_url.join(value).ok()?;
    if !is_playback_cdn_url(&target) {
        return None;
    }
    let encoded = URL_SAFE_NO_PAD.encode(target.as_str());
    Some(format!("/{route_secret}/{encoded}"))
}

fn parse_cdn_url(value: &str) -> Result<Url, CommandError> {
    let url = Url::parse(value).map_err(|_| invalid_cdn_url())?;
    if !is_playback_cdn_url(&url) {
        return Err(invalid_cdn_url());
    }
    Ok(url)
}

fn invalid_cdn_url() -> CommandError {
    CommandError::new(
        "native_probe_invalid_url",
        "The native audio probe accepts only secure SoundCloud CDN URLs.",
    )
}

fn respond_text(request: Request, status: u16, message: &str) {
    let mut response = Response::from_string(message).with_status_code(StatusCode(status));
    add_response_header(&mut response, "Content-Type", "text/plain; charset=utf-8");
    let _ = request.respond(response);
}

fn add_response_header<R: std::io::Read>(response: &mut Response<R>, name: &str, value: &str) {
    if let Ok(header) = Header::from_bytes(name, value) {
        response.add_header(header);
    }
}

fn relay_output(app: &AppHandle, files: &ProbeFiles, stop: Arc<AtomicBool>) -> Vec<JoinHandle<()>> {
    let event_app = app.clone();
    let output_path = files.output.clone();
    let output_stop = stop.clone();
    let output_thread = std::thread::spawn(move || {
        tail_file(&output_path, &output_stop, |line| {
            if let Ok(payload) = serde_json::from_str::<Value>(line) {
                let _ = event_app.emit(EVENT_NAME, payload);
            }
        });
        let _ = event_app.emit(EVENT_NAME, json!({ "type": "status", "state": "stopped" }));
    });

    let event_app = app.clone();
    let error_path = files.errors.clone();
    let error_thread = std::thread::spawn(move || {
        tail_file(&error_path, &stop, |message| {
            let _ = event_app.emit(EVENT_NAME, json!({ "type": "error", "message": message }));
        });
    });

    vec![output_thread, error_thread]
}

fn tail_file(path: &PathBuf, stop: &AtomicBool, mut receive: impl FnMut(&str)) {
    let Ok(file) = File::open(path) else { return };
    let mut reader = BufReader::new(file);
    let mut line = String::new();

    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) if stop.load(Ordering::Acquire) => break,
            Ok(0) => std::thread::sleep(Duration::from_millis(20)),
            Ok(_) => receive(line.trim_end()),
            Err(_) => break,
        }
    }
}

#[cfg(target_os = "macos")]
fn bundle_path(app: &AppHandle) -> Result<PathBuf, CommandError> {
    let development_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../native/audio-probe/build/SoundClaudeAudioProbe.app");
    if development_path.is_dir() {
        return Ok(development_path);
    }

    let resource_path = app
        .path()
        .resource_dir()
        .map_err(|_| probe_missing_error())?
        .join("SoundClaudeAudioProbe.app");
    resource_path
        .is_dir()
        .then_some(resource_path)
        .ok_or_else(probe_missing_error)
}

#[cfg(target_os = "macos")]
fn build_script_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../native/audio-probe/build.sh")
}

fn probe_missing_error() -> CommandError {
    CommandError::new(
        "native_probe_missing",
        "The native audio probe is not included in this app build.",
    )
}

fn probe_state_error() -> CommandError {
    CommandError::new(
        "native_probe_state_failed",
        "The native audio probe state is unavailable.",
    )
}

fn probe_files_error() -> CommandError {
    CommandError::new(
        "native_probe_files_failed",
        "The native audio probe files could not be prepared.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cdn_url_validation_rejects_lookalike_hosts() {
        assert!(is_playback_cdn_url(
            &Url::parse("https://cf-hls-media.sndcdn.com/media/track.m3u8").unwrap()
        ));
        assert!(is_playback_cdn_url(
            &Url::parse(
                "https://playback.media-streaming.soundcloud.cloud/track/aac_160k/id/playlist.m3u8"
            )
            .unwrap()
        ));
        assert!(!is_playback_cdn_url(
            &Url::parse("https://sndcdn.com.evil.example/track.m3u8").unwrap()
        ));
        assert!(!is_playback_cdn_url(
            &Url::parse("https://playback.media-streaming.soundcloud.cloud.evil.example/track")
                .unwrap()
        ));
    }

    #[test]
    fn playlist_rewrites_segments_and_uri_attributes() {
        let base = Url::parse("https://cf-hls-media.sndcdn.com/media/master.m3u8").unwrap();
        let playlist = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\npart-1.m4s\n";
        let rewritten = rewrite_playlist(playlist, &base, "secret");
        assert!(rewritten.contains("#EXT-X-MAP:URI=\"/secret/"));
        assert!(rewritten.contains("\n/secret/"));
        assert!(!rewritten.contains("part-1.m4s"));
    }
}
