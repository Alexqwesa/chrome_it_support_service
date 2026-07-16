// client.cpp
// -----------------------------------------------------------------------------
// Small Windows-only Chrome debug tunnel client.
//
// Reimplements the Dart agent in one native C++ file using only Windows APIs:
//   - WinHTTP WebSocket client
//   - WinSock local TCP forwarding
//   - CreateProcessW to launch Chrome
//   - small .env parser
//   - small JSON/base64 helpers for the existing Dart server protocol
//
// Compatible tunnel frame format:
//   {"type":"register", "pcName":"...", "windowsUser":"...", ...}
//   {"type":"data", "streamId":123, "base64":"..."}
//   {"type":"close", "streamId":123}
//
// Build with MSVC Developer Command Prompt:
//   cl /std:c++17 /O2 /MT /EHsc /DWIN32_LEAN_AND_MEAN client.cpp ^
//      winhttp.lib ws2_32.lib shell32.lib /link /OPT:REF /OPT:ICF /OUT:client.exe
//
// Build with MinGW-w64:
//   x86_64-w64-mingw32-g++ -std=c++17 -Os -s -DWIN32_LEAN_AND_MEAN ^
//      client.cpp -lwinhttp -lws2_32 -lshell32 -o client.exe
//
// Optional compiled defaults, MSVC example:
//   cl ... /DDEFAULT_RELAY_SERVER_URL=\"https://example.com\" ^
//          /DDEFAULT_AGENT_ENROLLMENT_TOKEN=\"secret\" ^
//          /DDEFAULT_AGENT_VERSION=\"1.0.0\"
//
// Runtime configuration priority:
//   1) compiled defaults
//   2) .env.example
//   3) .env
//   4) process environment variables
//
// Required variables:
//   RELAY_SERVER_URL=https://your-server.example.com
//   AGENT_ENROLLMENT_TOKEN=your-token
//
// Optional variables:
//   CHROME_PATH=C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe
//   AGENT_VERSION=1.0.0
// -----------------------------------------------------------------------------

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <winhttp.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <shellapi.h>

#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "shell32.lib")

#ifndef DEFAULT_RELAY_SERVER_URL
#define DEFAULT_RELAY_SERVER_URL ""
#endif
#ifndef DEFAULT_AGENT_ENROLLMENT_TOKEN
#define DEFAULT_AGENT_ENROLLMENT_TOKEN ""
#endif
#ifndef DEFAULT_AGENT_VERSION
#define DEFAULT_AGENT_VERSION ""
#endif
#ifndef DEFAULT_CHROME_PATH
#define DEFAULT_CHROME_PATH ""
#endif

using ByteVector = std::vector<unsigned char>;

static std::string last_error_text(const char* prefix) {
    DWORD code = GetLastError();
    LPSTR msg = nullptr;
    FormatMessageA(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr,
        code,
        MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        reinterpret_cast<LPSTR>(&msg),
        0,
        nullptr);

    std::ostringstream out;
    out << prefix << " failed, error " << code;
    if (msg) {
        out << ": " << msg;
        LocalFree(msg);
    }
    return out.str();
}

static std::wstring utf8_to_wide(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    if (n <= 0) return L"";
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
    return w;
}

static std::string wide_to_utf8(const std::wstring& w) {
    if (w.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0,
                                nullptr, nullptr);
    if (n <= 0) return "";
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), &s[0], n,
                        nullptr, nullptr);
    return s;
}

static std::string trim_copy(const std::string& s) {
    size_t a = 0;
    while (a < s.size() && std::isspace((unsigned char)s[a])) ++a;
    size_t b = s.size();
    while (b > a && std::isspace((unsigned char)s[b - 1])) --b;
    return s.substr(a, b - a);
}

static bool starts_with(const std::string& s, const std::string& prefix) {
    return s.size() >= prefix.size() &&
           s.compare(0, prefix.size(), prefix) == 0;
}

static bool file_exists_w(const std::wstring& path) {
    DWORD attrs = GetFileAttributesW(path.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY);
}

static std::string get_env_a(const std::string& key) {
    DWORD need = GetEnvironmentVariableA(key.c_str(), nullptr, 0);
    if (need == 0) return "";
    std::string value(need, '\0');
    DWORD got = GetEnvironmentVariableA(key.c_str(), &value[0], need);
    if (got == 0) return "";
    value.resize(got);
    return value;
}

static std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 16);
    for (unsigned char c : s) {
        switch (c) {
            case '\\': out += "\\\\"; break;
            case '"': out += "\\\""; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[7];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += (char)c;
                }
        }
    }
    return out;
}

static bool valid_env_key(const std::string& key) {
    if (key.empty()) return false;
    if (!(std::isalpha((unsigned char)key[0]) || key[0] == '_')) return false;
    for (char c : key) {
        if (!(std::isalnum((unsigned char)c) || c == '_')) return false;
    }
    return true;
}

static std::string unescape_double_quoted_env(const std::string& value) {
    std::string out;
    out.reserve(value.size());
    for (size_t i = 0; i < value.size(); ++i) {
        if (value[i] == '\\' && i + 1 < value.size()) {
            char n = value[++i];
            switch (n) {
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                default: out += n; break;
            }
        } else {
            out += value[i];
        }
    }
    return out;
}

static std::string parse_env_value(std::string raw) {
    raw = trim_copy(raw);
    if (raw.size() >= 2 &&
        ((raw.front() == '"' && raw.back() == '"') ||
         (raw.front() == '\'' && raw.back() == '\''))) {
        std::string inner = raw.substr(1, raw.size() - 2);
        return raw.front() == '"' ? unescape_double_quoted_env(inner) : inner;
    }
    size_t comment = raw.find(" #");
    if (comment != std::string::npos) raw = raw.substr(0, comment);
    return trim_copy(raw);
}

static void load_dotenv_file(const std::string& path,
                             std::map<std::string, std::string>& env) {
    std::ifstream in(path);
    if (!in) return;
    std::string line;
    while (std::getline(in, line)) {
        line = trim_copy(line);
        if (line.empty() || line[0] == '#') continue;
        if (starts_with(line, "export ")) line = trim_copy(line.substr(7));
        size_t eq = line.find('=');
        if (eq == std::string::npos || eq == 0) continue;
        std::string key = trim_copy(line.substr(0, eq));
        if (!valid_env_key(key)) continue;
        env[key] = parse_env_value(line.substr(eq + 1));
    }
}

static std::map<std::string, std::string> load_environment() {
    std::map<std::string, std::string> env;
    if (std::string(DEFAULT_RELAY_SERVER_URL).size()) {
        env["RELAY_SERVER_URL"] = DEFAULT_RELAY_SERVER_URL;
    }
    if (std::string(DEFAULT_AGENT_ENROLLMENT_TOKEN).size()) {
        env["AGENT_ENROLLMENT_TOKEN"] = DEFAULT_AGENT_ENROLLMENT_TOKEN;
    }
    if (std::string(DEFAULT_AGENT_VERSION).size()) {
        env["AGENT_VERSION"] = DEFAULT_AGENT_VERSION;
    }
    if (std::string(DEFAULT_CHROME_PATH).size()) {
        env["CHROME_PATH"] = DEFAULT_CHROME_PATH;
    }

    load_dotenv_file(".env.example", env);
    load_dotenv_file(".env", env);

    const char* keys[] = {
        "RELAY_SERVER_URL",
        "AGENT_ENROLLMENT_TOKEN",
        "AGENT_VERSION",
        "CHROME_PATH",
    };
    for (const char* key : keys) {
        std::string v = get_env_a(key);
        if (!v.empty()) env[key] = v;
    }
    return env;
}

static bool bad_required_value(const std::string& v) {
    return v.empty() || v == "change-me" || starts_with(v, "replace-with-");
}

static std::string utc_iso_now() {
    SYSTEMTIME st;
    GetSystemTime(&st);
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",
                  st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute,
                  st.wSecond, st.wMilliseconds);
    return buf;
}

static std::string computer_name() {
    char buf[MAX_COMPUTERNAME_LENGTH + 1];
    DWORD size = sizeof(buf);
    if (GetComputerNameA(buf, &size)) return std::string(buf, size);
    return "unknown";
}

static std::string windows_user() {
    char buf[256];
    DWORD size = sizeof(buf);
    if (GetUserNameA(buf, &size) && size > 0) return std::string(buf, size - 1);
    std::string u = get_env_a("USERNAME");
    return u.empty() ? "unknown" : u;
}

// -----------------------------------------------------------------------------
// Base64
// -----------------------------------------------------------------------------

static const char kB64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static std::string base64_encode(const ByteVector& data) {
    std::string out;
    out.reserve(((data.size() + 2) / 3) * 4);
    size_t i = 0;
    while (i + 2 < data.size()) {
        unsigned v = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
        out.push_back(kB64[(v >> 18) & 63]);
        out.push_back(kB64[(v >> 12) & 63]);
        out.push_back(kB64[(v >> 6) & 63]);
        out.push_back(kB64[v & 63]);
        i += 3;
    }
    if (i < data.size()) {
        unsigned v = data[i] << 16;
        bool two = false;
        if (i + 1 < data.size()) {
            v |= data[i + 1] << 8;
            two = true;
        }
        out.push_back(kB64[(v >> 18) & 63]);
        out.push_back(kB64[(v >> 12) & 63]);
        out.push_back(two ? kB64[(v >> 6) & 63] : '=');
        out.push_back('=');
    }
    return out;
}

static int b64_value(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static bool base64_decode(const std::string& s, ByteVector& out) {
    out.clear();
    int val = 0;
    int bits = -8;
    for (unsigned char c : s) {
        if (std::isspace(c)) continue;
        if (c == '=') break;
        int d = b64_value((char)c);
        if (d < 0) return false;
        val = (val << 6) + d;
        bits += 6;
        if (bits >= 0) {
            out.push_back((unsigned char)((val >> bits) & 0xFF));
            bits -= 8;
        }
    }
    return true;
}

// -----------------------------------------------------------------------------
// Tiny JSON field extractor.
// Enough for the agent protocol because frames are flat JSON objects.
// -----------------------------------------------------------------------------

static bool json_find_key(const std::string& json,
                          const std::string& key,
                          size_t& value_pos) {
    std::string quoted = "\"" + key + "\"";
    size_t pos = 0;
    while (true) {
        pos = json.find(quoted, pos);
        if (pos == std::string::npos) return false;
        size_t p = pos + quoted.size();
        while (p < json.size() && std::isspace((unsigned char)json[p])) ++p;
        if (p < json.size() && json[p] == ':') {
            ++p;
            while (p < json.size() && std::isspace((unsigned char)json[p])) ++p;
            value_pos = p;
            return true;
        }
        pos += quoted.size();
    }
}

static bool json_get_string(const std::string& json,
                            const std::string& key,
                            std::string& value) {
    size_t p = 0;
    if (!json_find_key(json, key, p) || p >= json.size() || json[p] != '"') {
        return false;
    }
    ++p;
    std::string out;
    while (p < json.size()) {
        char c = json[p++];
        if (c == '"') {
            value = out;
            return true;
        }
        if (c == '\\' && p < json.size()) {
            char e = json[p++];
            switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    // Keep non-ASCII unicode escapes as '?' to avoid a full JSON decoder.
                    if (p + 4 <= json.size()) p += 4;
                    out += '?';
                    break;
                }
                default: out += e; break;
            }
        } else {
            out += c;
        }
    }
    return false;
}

static bool json_get_int(const std::string& json,
                         const std::string& key,
                         int& value) {
    size_t p = 0;
    if (!json_find_key(json, key, p)) return false;
    bool neg = false;
    if (p < json.size() && json[p] == '-') {
        neg = true;
        ++p;
    }
    if (p >= json.size() || !std::isdigit((unsigned char)json[p])) return false;
    long long v = 0;
    while (p < json.size() && std::isdigit((unsigned char)json[p])) {
        v = v * 10 + (json[p++] - '0');
        if (v > 2147483647LL) return false;
    }
    value = neg ? -(int)v : (int)v;
    return true;
}

struct Frame {
    std::string type;
    int stream_id = -1;
    bool has_stream_id = false;
    ByteVector data;
    bool has_data = false;
    std::string message;
    std::string target_id;
    int server_port = -1;
};

static bool parse_frame(const std::string& raw, Frame& f, std::string& error) {
    if (!json_get_string(raw, "type", f.type)) {
        error = "Tunnel frame type is missing.";
        return false;
    }
    int stream_id = 0;
    if (json_get_int(raw, "streamId", stream_id)) {
        f.stream_id = stream_id;
        f.has_stream_id = true;
    }
    std::string b64;
    if (json_get_string(raw, "base64", b64)) {
        if (!base64_decode(b64, f.data)) {
            error = "Invalid base64 data.";
            return false;
        }
        f.has_data = true;
    }
    json_get_string(raw, "message", f.message);
    json_get_string(raw, "targetId", f.target_id);
    json_get_int(raw, "serverPort", f.server_port);
    return true;
}

static std::string frame_heartbeat() {
    return "{\"type\":\"heartbeat\"}";
}

static std::string frame_close(int stream_id) {
    return "{\"type\":\"close\",\"streamId\":" + std::to_string(stream_id) + "}";
}

static std::string frame_error(int stream_id, const std::string& message) {
    return "{\"type\":\"error\",\"streamId\":" + std::to_string(stream_id) +
           ",\"message\":\"" + json_escape(message) + "\"}";
}

static std::string frame_data(int stream_id, const ByteVector& data) {
    return "{\"type\":\"data\",\"streamId\":" + std::to_string(stream_id) +
           ",\"base64\":\"" + base64_encode(data) + "\"}";
}

static std::string frame_register_agent(const std::string& pc_name,
                                        const std::string& user,
                                        int chrome_port,
                                        const std::string& version) {
    std::ostringstream out;
    out << "{\"type\":\"register\""
        << ",\"pcName\":\"" << json_escape(pc_name) << "\""
        << ",\"windowsUser\":\"" << json_escape(user) << "\""
        << ",\"localChromePort\":" << chrome_port
        << ",\"agentVersion\":\"" << json_escape(version) << "\""
        << ",\"startedAt\":\"" << utc_iso_now() << "\""
        << "}";
    return out.str();
}

static std::string frame_add_target(const std::string& target_id,
                                    const std::string& label,
                                    int chrome_port) {
    std::ostringstream out;
    out << "{\"type\":\"addTarget\""
        << ",\"targetId\":\"" << json_escape(target_id) << "\""
        << ",\"label\":\"" << json_escape(label) << "\""
        << ",\"localChromePort\":" << chrome_port
        << "}";
    return out.str();
}

// -----------------------------------------------------------------------------
// URL handling
// -----------------------------------------------------------------------------

struct ParsedUrl {
    std::string scheme;
    std::wstring host;
    INTERNET_PORT port = 0;
    std::wstring path;
    bool secure = false;
};

static bool parse_agent_url(const std::string& input,
                            ParsedUrl& parsed,
                            std::string& error) {
    std::string crack_input = input;
    std::string explicit_scheme;
    if (starts_with(crack_input, "ws://")) {
        explicit_scheme = "ws";
        crack_input = "http://" + crack_input.substr(5);
    } else if (starts_with(crack_input, "wss://")) {
        explicit_scheme = "wss";
        crack_input = "https://" + crack_input.substr(6);
    }

    std::wstring w = utf8_to_wide(crack_input);
    if (w.empty()) {
        error = "RELAY_SERVER_URL is empty or invalid UTF-8.";
        return false;
    }

    URL_COMPONENTS uc{};
    uc.dwStructSize = sizeof(uc);
    wchar_t scheme[16]{};
    wchar_t host[512]{};
    wchar_t path[2048]{};
    uc.lpszScheme = scheme;
    uc.dwSchemeLength = _countof(scheme);
    uc.lpszHostName = host;
    uc.dwHostNameLength = _countof(host);
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = _countof(path);

    if (!WinHttpCrackUrl(w.c_str(), 0, 0, &uc)) {
        error = "RELAY_SERVER_URL must use http, https, ws, or wss.";
        return false;
    }

    parsed.scheme = explicit_scheme.empty()
                        ? wide_to_utf8(std::wstring(uc.lpszScheme, uc.dwSchemeLength))
                        : explicit_scheme;
    parsed.host.assign(uc.lpszHostName, uc.dwHostNameLength);
    parsed.port = uc.nPort;
    parsed.path = L"/agent";

    if (parsed.scheme == "https") parsed.scheme = "wss";
    if (parsed.scheme == "http") parsed.scheme = "ws";

    if (parsed.scheme == "wss") {
        parsed.secure = true;
        if (parsed.port == 0) parsed.port = INTERNET_DEFAULT_HTTPS_PORT;
    } else if (parsed.scheme == "ws") {
        parsed.secure = false;
        if (parsed.port == 0) parsed.port = INTERNET_DEFAULT_HTTP_PORT;
    } else {
        error = "RELAY_SERVER_URL must use http, https, ws, or wss.";
        return false;
    }

    if (parsed.host.empty()) {
        error = "RELAY_SERVER_URL host is empty.";
        return false;
    }
    return true;
}

// -----------------------------------------------------------------------------
// WinHTTP WebSocket wrapper
// -----------------------------------------------------------------------------

class WebSocketClient {
public:
    ~WebSocketClient() { close("shutdown"); }

    bool connect_to(const ParsedUrl& url,
                    const std::string& bearer_token,
                    std::string& error) {
        close_handles();
        session_ = WinHttpOpen(
            L"VSP Chrome Debug Agent/1.0",
            WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
            WINHTTP_NO_PROXY_NAME,
            WINHTTP_NO_PROXY_BYPASS,
            0);
        if (!session_) {
            error = last_error_text("WinHttpOpen");
            return false;
        }
        WinHttpSetTimeouts(session_, 5000, 5000, 10000, 30000);

        connect_ = WinHttpConnect(session_, url.host.c_str(), url.port, 0);
        if (!connect_) {
            error = last_error_text("WinHttpConnect");
            return false;
        }

        DWORD flags = url.secure ? WINHTTP_FLAG_SECURE : 0;
        request_ = WinHttpOpenRequest(connect_, L"GET", url.path.c_str(),
                                      nullptr, WINHTTP_NO_REFERER,
                                      WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
        if (!request_) {
            error = last_error_text("WinHttpOpenRequest");
            return false;
        }

        if (!WinHttpSetOption(request_, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET,
                              nullptr, 0)) {
            error = last_error_text("WinHttpSetOption(UPGRADE_TO_WEB_SOCKET)");
            return false;
        }

        std::wstring headers = L"Authorization: Bearer " +
                               utf8_to_wide(bearer_token) + L"\r\n";
        if (!WinHttpSendRequest(request_, headers.c_str(),
                                (DWORD)-1L, nullptr, 0, 0, 0)) {
            error = last_error_text("WinHttpSendRequest");
            return false;
        }
        if (!WinHttpReceiveResponse(request_, nullptr)) {
            error = last_error_text("WinHttpReceiveResponse");
            return false;
        }

        DWORD status = 0;
        DWORD status_size = sizeof(status);
        if (WinHttpQueryHeaders(request_,
                                WINHTTP_QUERY_STATUS_CODE |
                                    WINHTTP_QUERY_FLAG_NUMBER,
                                WINHTTP_HEADER_NAME_BY_INDEX,
                                &status,
                                &status_size,
                                WINHTTP_NO_HEADER_INDEX)) {
            if (status == 401) {
                error = "Server rejected AGENT_ENROLLMENT_TOKEN, HTTP 401.";
                return false;
            }
            if (status != 101) {
                error = "WebSocket upgrade failed, HTTP status " +
                        std::to_string(status) + ".";
                return false;
            }
        }

        websocket_ = WinHttpWebSocketCompleteUpgrade(request_, 0);
        if (!websocket_) {
            error = last_error_text("WinHttpWebSocketCompleteUpgrade");
            return false;
        }

        WinHttpCloseHandle(request_);
        request_ = nullptr;
        connected_.store(true);
        return true;
    }

    bool send_text(const std::string& text) {
        std::lock_guard<std::mutex> lock(send_mutex_);
        if (!connected_.load() || !websocket_) return false;
        DWORD rc = WinHttpWebSocketSend(
            websocket_,
            WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
            (void*)text.data(),
            (DWORD)text.size());
        if (rc != ERROR_SUCCESS) {
            connected_.store(false);
            return false;
        }
        return true;
    }

    template <typename Callback>
    void receive_loop(Callback on_message) {
        std::string message;
        std::vector<char> buffer(64 * 1024);
        while (connected_.load() && websocket_) {
            DWORD bytes = 0;
            WINHTTP_WEB_SOCKET_BUFFER_TYPE type{};
            DWORD rc = WinHttpWebSocketReceive(websocket_, buffer.data(),
                                               (DWORD)buffer.size(),
                                               &bytes, &type);
            if (rc != ERROR_SUCCESS) break;
            if (type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) break;

            if (type == WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE ||
                type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE) {
                message.append(buffer.data(), buffer.data() + bytes);
                if (type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE) {
                    on_message(message);
                    message.clear();
                }
            }
        }
        connected_.store(false);
    }

    void close(const std::string& reason) {
        std::lock_guard<std::mutex> lock(send_mutex_);
        connected_.store(false);
        if (websocket_) {
            std::string safe = reason.substr(0, 120);
            WinHttpWebSocketClose(websocket_,
                                  WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS,
                                  (void*)safe.data(),
                                  (DWORD)safe.size());
        }
        close_handles();
    }

    bool connected() const { return connected_.load(); }

private:
    void close_handles() {
        if (websocket_) {
            WinHttpCloseHandle(websocket_);
            websocket_ = nullptr;
        }
        if (request_) {
            WinHttpCloseHandle(request_);
            request_ = nullptr;
        }
        if (connect_) {
            WinHttpCloseHandle(connect_);
            connect_ = nullptr;
        }
        if (session_) {
            WinHttpCloseHandle(session_);
            session_ = nullptr;
        }
    }

    HINTERNET session_ = nullptr;
    HINTERNET connect_ = nullptr;
    HINTERNET request_ = nullptr;
    HINTERNET websocket_ = nullptr;
    std::atomic<bool> connected_{false};
    std::mutex send_mutex_;
};

// -----------------------------------------------------------------------------
// Chrome launcher
// -----------------------------------------------------------------------------

struct ChromeSession {
    PROCESS_INFORMATION process{};
    int port = 0;
    std::wstring profile_dir;
};

static std::wstring join_path(const std::wstring& a, const std::wstring& b) {
    if (a.empty()) return b;
    if (a.back() == L'\\' || a.back() == L'/') return a + b;
    return a + L"\\" + b;
}

static std::wstring env_w(const wchar_t* key) {
    DWORD need = GetEnvironmentVariableW(key, nullptr, 0);
    if (!need) return L"";
    std::wstring value(need, L'\0');
    DWORD got = GetEnvironmentVariableW(key, &value[0], need);
    if (!got) return L"";
    value.resize(got);
    return value;
}

static bool find_chrome(const std::string& configured_path,
                        std::wstring& chrome,
                        std::string& error) {
    std::vector<std::wstring> candidates;
    if (!configured_path.empty()) candidates.push_back(utf8_to_wide(configured_path));

    std::wstring pf = env_w(L"PROGRAMFILES");
    std::wstring pfx86 = env_w(L"PROGRAMFILES(X86)");
    std::wstring local = env_w(L"LOCALAPPDATA");
    if (!pf.empty()) candidates.push_back(join_path(pf, L"Google\\Chrome\\Application\\chrome.exe"));
    if (!pfx86.empty()) candidates.push_back(join_path(pfx86, L"Google\\Chrome\\Application\\chrome.exe"));
    if (!local.empty()) candidates.push_back(join_path(local, L"Google\\Chrome\\Application\\chrome.exe"));

    for (const auto& c : candidates) {
        if (!c.empty() && file_exists_w(c)) {
            chrome = c;
            return true;
        }
    }

    wchar_t found[MAX_PATH];
    DWORD n = SearchPathW(nullptr, L"chrome.exe", nullptr, MAX_PATH, found, nullptr);
    if (n > 0 && n < MAX_PATH && file_exists_w(found)) {
        chrome = found;
        return true;
    }

    error = "Google Chrome was not found. Set CHROME_PATH to chrome.exe.";
    return false;
}

static SOCKET bind_test_socket(int port) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return INVALID_SOCKET;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char*)&yes, sizeof(yes));
    if (bind(s, (sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
        closesocket(s);
        return INVALID_SOCKET;
    }
    return s;
}

static bool find_free_port(int start, int end, int& port, std::string& error) {
    for (int p = start; p <= end; ++p) {
        SOCKET s = bind_test_socket(p);
        if (s != INVALID_SOCKET) {
            closesocket(s);
            port = p;
            return true;
        }
    }
    error = "No free Chrome debug port in " + std::to_string(start) + "-" +
            std::to_string(end) + ".";
    return false;
}

static std::wstring quote_arg(const std::wstring& arg) {
    std::wstring out = L"\"";
    for (wchar_t c : arg) {
        if (c == L'\"') out += L"\\\"";
        else out += c;
    }
    out += L"\"";
    return out;
}

static bool make_temp_profile_dir(std::wstring& dir, std::string& error) {
    wchar_t temp[MAX_PATH];
    DWORD n = GetTempPathW(MAX_PATH, temp);
    if (n == 0 || n >= MAX_PATH) {
        error = last_error_text("GetTempPathW");
        return false;
    }
    std::wostringstream name;
    name << L"vsp-debug-chrome-" << GetCurrentProcessId() << L"-" << GetTickCount64();
    dir = join_path(temp, name.str());
    if (!CreateDirectoryW(dir.c_str(), nullptr)) {
        error = last_error_text("CreateDirectoryW(profile)");
        return false;
    }
    return true;
}

static bool http_get_ok_local(int port) {
    HINTERNET session = WinHttpOpen(L"VSP Chrome Probe/1.0",
                                    WINHTTP_ACCESS_TYPE_NO_PROXY,
                                    WINHTTP_NO_PROXY_NAME,
                                    WINHTTP_NO_PROXY_BYPASS,
                                    0);
    if (!session) return false;
    WinHttpSetTimeouts(session, 1000, 1000, 1000, 2000);
    HINTERNET conn = WinHttpConnect(session, L"127.0.0.1", (INTERNET_PORT)port, 0);
    if (!conn) {
        WinHttpCloseHandle(session);
        return false;
    }
    HINTERNET req = WinHttpOpenRequest(conn, L"GET", L"/json/version",
                                       nullptr, WINHTTP_NO_REFERER,
                                       WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
    bool ok = false;
    if (req && WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                  nullptr, 0, 0, 0) &&
        WinHttpReceiveResponse(req, nullptr)) {
        DWORD status = 0;
        DWORD len = sizeof(status);
        if (WinHttpQueryHeaders(req,
                                WINHTTP_QUERY_STATUS_CODE |
                                    WINHTTP_QUERY_FLAG_NUMBER,
                                WINHTTP_HEADER_NAME_BY_INDEX,
                                &status,
                                &len,
                                WINHTTP_NO_HEADER_INDEX)) {
            ok = status == 200;
        }
    }
    if (req) WinHttpCloseHandle(req);
    WinHttpCloseHandle(conn);
    WinHttpCloseHandle(session);
    return ok;
}

static void recursive_delete_dir(const std::wstring& dir) {
    std::wstring mask = join_path(dir, L"*");
    WIN32_FIND_DATAW fd{};
    HANDLE h = FindFirstFileW(mask.c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            std::wstring name = fd.cFileName;
            if (name == L"." || name == L"..") continue;
            std::wstring path = join_path(dir, name);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                recursive_delete_dir(path);
            } else {
                SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(path.c_str());
            }
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    RemoveDirectoryW(dir.c_str());
}

static bool start_chrome(const std::string& configured_path,
                         ChromeSession& session,
                         std::string& error) {
    std::wstring chrome;
    if (!find_chrome(configured_path, chrome, error)) return false;
    if (!find_free_port(9222, 9299, session.port, error)) return false;
    if (!make_temp_profile_dir(session.profile_dir, error)) return false;

    std::wostringstream cmd;
    cmd << quote_arg(chrome)
        << L" --remote-debugging-address=127.0.0.1"
        << L" --remote-debugging-port=" << session.port
        << L" --user-data-dir=" << quote_arg(session.profile_dir)
        << L" --no-first-run"
        << L" --no-default-browser-check"
        << L" about:blank";

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    std::wstring cmdline = cmd.str();
    if (!CreateProcessW(chrome.c_str(), &cmdline[0], nullptr, nullptr, FALSE,
                        CREATE_NEW_PROCESS_GROUP, nullptr, nullptr, &si,
                        &session.process)) {
        error = last_error_text("CreateProcessW(chrome)");
        recursive_delete_dir(session.profile_dir);
        return false;
    }

    for (int attempt = 0; attempt < 30; ++attempt) {
        if (WaitForSingleObject(session.process.hProcess, 0) == WAIT_OBJECT_0) {
            error = "Chrome exited before its debug endpoint was ready.";
            return false;
        }
        if (http_get_ok_local(session.port)) return true;
        Sleep(500);
    }
    error = "Chrome debug endpoint did not become ready.";
    return false;
}

static void stop_chrome(ChromeSession& session) {
    if (session.process.hProcess) {
        TerminateProcess(session.process.hProcess, 0);
        WaitForSingleObject(session.process.hProcess, 5000);
        CloseHandle(session.process.hProcess);
        session.process.hProcess = nullptr;
    }
    if (session.process.hThread) {
        CloseHandle(session.process.hThread);
        session.process.hThread = nullptr;
    }
    if (!session.profile_dir.empty()) {
        recursive_delete_dir(session.profile_dir);
        session.profile_dir.clear();
    }
}

// -----------------------------------------------------------------------------
// TCP stream forwarding
// -----------------------------------------------------------------------------

struct StreamState {
    int id = -1;
    SOCKET sock = INVALID_SOCKET;
    bool closing = false;
    std::vector<ByteVector> pending;
};

static bool send_all_socket(SOCKET s, const unsigned char* data, int len) {
    int sent = 0;
    while (sent < len) {
        int n = send(s, (const char*)data + sent, len - sent, 0);
        if (n <= 0) return false;
        sent += n;
    }
    return true;
}

static SOCKET connect_loopback(int port) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return INVALID_SOCKET;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (connect(s, (sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
        closesocket(s);
        return INVALID_SOCKET;
    }
    return s;
}

// -----------------------------------------------------------------------------
// Agent
// -----------------------------------------------------------------------------

class Agent;
static Agent* g_agent = nullptr;

class Agent {
public:
    Agent(std::string server_url,
          std::string token,
          std::string chrome_path,
          std::string version)
        : server_url_(std::move(server_url)),
          token_(std::move(token)),
          chrome_path_(std::move(chrome_path)),
          version_(version.empty() ? "1.0.0" : std::move(version)) {}

    int run() {
        std::string pc = computer_name();
        std::string user = windows_user();

        std::cout << "VSP Chrome Debug Agent\n\n"
                  << "PC name: " << pc << "\n"
                  << "User: " << user << "\n"
                  << "Server: " << server_url_ << "\n\n"
                  << "Starting Chrome debug profile...\n";

        std::string error;
        if (!start_chrome(chrome_path_, chrome_, error)) {
            std::cerr << error << "\n";
            stop_chrome(chrome_);
            return 1;
        }

        {
            std::lock_guard<std::mutex> lock(target_mutex_);
            target_ports_["default"] = chrome_.port;
        }
        std::cout << "Chrome debug endpoint: 127.0.0.1:" << chrome_.port << "\n\n";

        ParsedUrl url;
        if (!parse_agent_url(server_url_, url, error)) {
            std::cerr << error << "\n";
            stop_chrome(chrome_);
            return 1;
        }

        if (!websocket_.connect_to(url, token_, error)) {
            std::cerr << error << "\n";
            stop_chrome(chrome_);
            return 1;
        }

        websocket_.send_text(frame_register_agent(pc, user, chrome_.port, version_));

        std::thread(&Agent::heartbeat_loop, this).detach();
        std::thread(&Agent::console_loop, this).detach();

        websocket_.receive_loop([this](const std::string& msg) {
            handle_frame(msg);
        });

        stop("server disconnected");
        return 0;
    }

    void stop(const std::string& reason) {
        bool expected = false;
        if (!stopping_.compare_exchange_strong(expected, true)) return;

        std::cout << "\nStopping agent: " << reason << "\n";

        {
            std::lock_guard<std::mutex> lock(stream_mutex_);
            for (auto& kv : streams_) {
                if (kv.second->sock != INVALID_SOCKET) {
                    closesocket(kv.second->sock);
                    kv.second->sock = INVALID_SOCKET;
                }
            }
            streams_.clear();
        }

        websocket_.close(reason);
        stop_chrome(chrome_);
    }

private:
    void heartbeat_loop() {
        while (!stopping_.load()) {
            for (int i = 0; i < 15 && !stopping_.load(); ++i) Sleep(1000);
            if (!stopping_.load()) websocket_.send_text(frame_heartbeat());
        }
    }

    static bool parse_loopback_endpoint(const std::string& line, int& port) {
        std::string s = trim_copy(line);
        if (s.empty()) return false;
        if (starts_with(s, "http://")) s = s.substr(7);
        if (starts_with(s, "https://")) s = s.substr(8);
        if (starts_with(s, "ws://")) s = s.substr(5);
        if (starts_with(s, "wss://")) s = s.substr(6);
        size_t slash = s.find('/');
        if (slash != std::string::npos) s = s.substr(0, slash);
        size_t colon = s.rfind(':');
        if (colon == std::string::npos) return false;
        std::string host = s.substr(0, colon);
        std::string p = s.substr(colon + 1);
        if (!(host == "127.0.0.1" || host == "localhost")) return false;
        if (p.empty()) return false;
        for (char c : p) if (!std::isdigit((unsigned char)c)) return false;
        int v = std::atoi(p.c_str());
        if (v <= 0 || v > 65535) return false;
        port = v;
        return true;
    }

    void console_loop() {
        std::cout << "==================================================================\n"
                  << "Optional: to connect to a previously opened Chrome window, open\n"
                  << "chrome://inspect/#remote-debugging in that Chrome and paste its\n"
                  << "127.0.0.1:PORT debug address here, then press Enter.\n"
                  << "------------------------------------------------------------------\n";

        std::string line;
        while (!stopping_.load() && std::getline(std::cin, line)) {
            int port = 0;
            if (!parse_loopback_endpoint(line, port)) {
                if (!trim_copy(line).empty()) {
                    std::cout << "Enter a loopback Chrome debug address like 127.0.0.1:9222.\n";
                }
                continue;
            }
            int id = next_target_id_.fetch_add(1);
            std::string target_id = "manual-" + std::to_string(id);
            {
                std::lock_guard<std::mutex> lock(target_mutex_);
                target_ports_[target_id] = port;
            }
            websocket_.send_text(frame_add_target(
                target_id,
                "Existing Chrome 127.0.0.1:" + std::to_string(port),
                port));
            std::cout << "Requested forwarding for existing Chrome endpoint 127.0.0.1:"
                      << port << ".\n";
        }
    }

    void handle_frame(const std::string& raw) {
        Frame f;
        std::string error;
        if (!parse_frame(raw, f, error)) {
            std::cerr << "Invalid server frame: " << error << "\n";
            return;
        }

        if (f.type == "registered") {
            std::cout << "Connected to server.\n";
            if (f.server_port > 0) {
                std::cout << "Assigned server port: " << f.server_port << "\n";
            }
            std::cout << "\nDo not close this window while support is connected.\n"
                      << "Press Ctrl+C to stop.\n\n";
            return;
        }

        if (f.type == "targetRegistered") {
            std::cout << "\nAdditional Chrome endpoint registered.\n";
            int local_port = -1;
            json_get_int(raw, "localChromePort", local_port);
            if (local_port > 0) {
                std::cout << "Local Chrome: 127.0.0.1:" << local_port << "\n";
            }
            if (f.server_port > 0) {
                std::cout << "Assigned server port: " << f.server_port << "\n";
            }
            std::cout << "Ask the operator to refresh /debug-sessions and copy the new SSH command.\n";
            return;
        }

        if (f.type == "open") {
            if (f.has_stream_id) {
                std::string target = f.target_id.empty() ? "default" : f.target_id;
                std::thread(&Agent::open_stream, this, f.stream_id, target).detach();
            }
            return;
        }

        if (f.type == "data") {
            if (f.has_stream_id && f.has_data) write_stream(f.stream_id, f.data);
            return;
        }

        if (f.type == "close" || f.type == "error") {
            if (f.has_stream_id) close_stream(f.stream_id, false);
            return;
        }

        // heartbeat/register/addTarget from server are ignored, matching Dart logic.
    }

    int target_port(const std::string& target_id) {
        std::lock_guard<std::mutex> lock(target_mutex_);
        auto it = target_ports_.find(target_id);
        return it == target_ports_.end() ? -1 : it->second;
    }

    void open_stream(int stream_id, const std::string& target_id) {
        if (stopping_.load()) return;

        auto state = std::make_shared<StreamState>();
        state->id = stream_id;
        {
            std::lock_guard<std::mutex> lock(stream_mutex_);
            if (streams_.count(stream_id)) return;
            streams_[stream_id] = state;
        }

        int port = target_port(target_id);
        if (port <= 0) {
            remove_stream_no_notify(stream_id);
            websocket_.send_text(frame_error(stream_id, "Unknown Chrome endpoint target: " + target_id));
            return;
        }

        SOCKET s = connect_loopback(port);
        if (s == INVALID_SOCKET) {
            remove_stream_no_notify(stream_id);
            websocket_.send_text(frame_error(stream_id, "Local Chrome connection failed."));
            return;
        }

        {
            std::lock_guard<std::mutex> lock(stream_mutex_);
            auto it = streams_.find(stream_id);
            if (it == streams_.end() || it->second != state) {
                closesocket(s);
                return;
            }
            state->sock = s;
            for (const auto& p : state->pending) {
                if (!send_all_socket(s, p.data(), (int)p.size())) break;
            }
            state->pending.clear();
        }

        unsigned char buf[16 * 1024];
        while (!stopping_.load()) {
            int n = recv(s, (char*)buf, sizeof(buf), 0);
            if (n <= 0) break;
            ByteVector data(buf, buf + n);
            if (!websocket_.send_text(frame_data(stream_id, data))) break;
        }

        close_stream(stream_id, true);
    }

    void write_stream(int stream_id, const ByteVector& data) {
        std::shared_ptr<StreamState> state;
        SOCKET s = INVALID_SOCKET;
        {
            std::lock_guard<std::mutex> lock(stream_mutex_);
            auto it = streams_.find(stream_id);
            if (it == streams_.end()) return;
            state = it->second;
            s = state->sock;
            if (s == INVALID_SOCKET) {
                state->pending.push_back(data);
                return;
            }
        }
        if (!send_all_socket(s, data.data(), (int)data.size())) {
            websocket_.send_text(frame_error(stream_id, "Local socket write failed."));
            close_stream(stream_id, true);
        }
    }

    void remove_stream_no_notify(int stream_id) {
        std::lock_guard<std::mutex> lock(stream_mutex_);
        auto it = streams_.find(stream_id);
        if (it != streams_.end()) {
            if (it->second->sock != INVALID_SOCKET) closesocket(it->second->sock);
            streams_.erase(it);
        }
    }

    void close_stream(int stream_id, bool notify_peer) {
        bool removed = false;
        {
            std::lock_guard<std::mutex> lock(stream_mutex_);
            auto it = streams_.find(stream_id);
            if (it != streams_.end()) {
                if (it->second->sock != INVALID_SOCKET) {
                    closesocket(it->second->sock);
                    it->second->sock = INVALID_SOCKET;
                }
                streams_.erase(it);
                removed = true;
            }
        }
        if (removed && notify_peer && !stopping_.load()) {
            websocket_.send_text(frame_close(stream_id));
        }
    }

    std::string server_url_;
    std::string token_;
    std::string chrome_path_;
    std::string version_;

    ChromeSession chrome_;
    WebSocketClient websocket_;

    std::atomic<bool> stopping_{false};
    std::atomic<int> next_target_id_{1};

    std::mutex target_mutex_;
    std::map<std::string, int> target_ports_;

    std::mutex stream_mutex_;
    std::map<int, std::shared_ptr<StreamState>> streams_;
};

static BOOL WINAPI console_handler(DWORD type) {
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT ||
        type == CTRL_CLOSE_EVENT || type == CTRL_SHUTDOWN_EVENT) {
        if (g_agent) g_agent->stop("console signal");
        return TRUE;
    }
    return FALSE;
}

int main() {
    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        std::cerr << "WSAStartup failed.\n";
        return 1;
    }

    auto env = load_environment();
    std::string server_url = env["RELAY_SERVER_URL"];
    std::string token = env["AGENT_ENROLLMENT_TOKEN"];
    std::string version = env.count("AGENT_VERSION") ? env["AGENT_VERSION"] : "1.0.0";
    std::string chrome_path = env.count("CHROME_PATH") ? env["CHROME_PATH"] : "";

    if (bad_required_value(server_url)) {
        std::cerr << "RELAY_SERVER_URL must be set to a non-default value.\n";
        WSACleanup();
        return 1;
    }
    if (bad_required_value(token)) {
        std::cerr << "AGENT_ENROLLMENT_TOKEN must be set to a non-default value.\n";
        WSACleanup();
        return 1;
    }

    Agent agent(server_url, token, chrome_path, version);
    g_agent = &agent;
    SetConsoleCtrlHandler(console_handler, TRUE);

    int rc = agent.run();

    SetConsoleCtrlHandler(console_handler, FALSE);
    g_agent = nullptr;
    WSACleanup();
    return rc;
}
