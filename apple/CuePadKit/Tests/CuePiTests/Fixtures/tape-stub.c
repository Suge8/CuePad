// 真 Agent 的替身进程（见 AgentTape.swift）：CuePad 照常起它、给它写标准输入、给它发信号、等它退出；它把这些都转给测试进程里的录像机，
// 再把录像机给的标准输出、标准错误与退出原样做出来。录制时录像机背后是真 Agent，回放时是录好的数据。
// 录像机的 socket 是可执行文件所在目录的上一级的 t.sock（每盘录像带把它复制进自己的 bin/）。
// 与录像机之间一行一条："i <b64>" 标准输入、"e" 输入结束、"s <信号>" 收到信号；回来 "o <b64>" 标准输出、"r <b64>" 标准错误、
// "x <退出码>" 退出、"k <信号>" 被这个信号结束、"f" 等写进标准输出的都被读走了再回 "f"（回放时换通道前的同步点）。
// 用 C：每个用例要起好几个替身，脚本解释器的启动开销会占掉回放的大半时间。
#include <errno.h>
#include <libgen.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

extern char **environ;
static int sock = -1;
static int wake[2];
static volatile sig_atomic_t received[32];

static void put(const char *data, size_t length) {
    while (length > 0) {
        ssize_t n = write(sock, data, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) _exit(1);
        data += n;
        length -= (size_t)n;
    }
}

static void put_all(int fd, const char *data, size_t length) {
    while (length > 0) {
        ssize_t n = write(fd, data, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        data += n;
        length -= (size_t)n;
    }
}

static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void put_b64(const char *prefix, const unsigned char *data, size_t length) {
    size_t size = strlen(prefix) + (length + 2) / 3 * 4 + 2;
    char *line = malloc(size), *out = line;
    out += sprintf(out, "%s", prefix);
    for (size_t i = 0; i < length; i += 3) {
        unsigned v = data[i] << 16 | (i + 1 < length ? data[i + 1] << 8 : 0) | (i + 2 < length ? data[i + 2] : 0);
        *out++ = table[v >> 18 & 63];
        *out++ = table[v >> 12 & 63];
        *out++ = i + 1 < length ? table[v >> 6 & 63] : '=';
        *out++ = i + 2 < length ? table[v & 63] : '=';
    }
    *out++ = '\n';
    put(line, (size_t)(out - line));
    free(line);
}

static size_t decode_b64(const char *text, unsigned char *out) {
    size_t n = 0;
    unsigned v = 0;
    int bits = 0;
    for (; *text && *text != '='; text++) {
        const char *p = strchr(table, *text);
        if (!p) continue;
        v = v << 6 | (unsigned)(p - table);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n++] = (unsigned char)(v >> bits & 0xFF);
        }
    }
    return n;
}

static void on_signal(int number) {
    if (number < 32) received[number] = 1;
    char byte = 0;
    write(wake[1], &byte, 1);
}

static void handle(char *line) {
    char kind = line[0];
    char *value = line[1] == ' ' ? line + 2 : line + 1;
    if (kind == 'o' || kind == 'r') {
        size_t length = strlen(value);
        unsigned char *data = malloc(length + 1);
        size_t n = decode_b64(value, data);
        put_all(kind == 'o' ? STDOUT_FILENO : STDERR_FILENO, (const char *)data, n);
        free(data);
    } else if (kind == 'x') {
        _exit(atoi(value));
    } else if (kind == 'k') {
        int number = atoi(value);
        signal(number, SIG_DFL);
        kill(getpid(), number);
        _exit(1);
    } else if (kind == 'f') {
        for (int i = 0; i < 4000; i++) {
            struct stat info;
            if (fstat(STDOUT_FILENO, &info) != 0 || info.st_size == 0) break;
            usleep(500);
        }
        put("f\n", 2);
    }
}

int main(int argc, char **argv) {
    char exe[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(getpid(), exe, sizeof exe) <= 0) return 127;
    char directory[PROC_PIDPATHINFO_MAXSIZE], name[PROC_PIDPATHINFO_MAXSIZE];
    strlcpy(directory, exe, sizeof directory);
    strlcpy(name, basename(exe), sizeof name);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    snprintf(address.sun_path, sizeof address.sun_path, "%s/t.sock", dirname(dirname(directory)));
    sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (connect(sock, (struct sockaddr *)&address, sizeof address) != 0) {
        fprintf(stderr, "tape-stub: %s: %s\n", address.sun_path, strerror(errno));
        return 127;
    }
    int one = 1;
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    signal(SIGPIPE, SIG_IGN);

    put_b64("n ", (const unsigned char *)name, strlen(name));
    char header[64];
    put(header, (size_t)snprintf(header, sizeof header, "p %d\n", getpid()));
    char cwd[4096];
    if (!getcwd(cwd, sizeof cwd)) cwd[0] = 0;
    put_b64("w ", (const unsigned char *)cwd, strlen(cwd));
    for (int i = 1; i < argc; i++) put_b64("a ", (const unsigned char *)argv[i], strlen(argv[i]));
    for (char **e = environ; *e; e++) put_b64("v ", (const unsigned char *)*e, strlen(*e));
    put("h\n", 2);

    pipe(wake);
    int numbers[] = {SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2};
    for (size_t i = 0; i < sizeof numbers / sizeof *numbers; i++) {
        struct sigaction action = {.sa_handler = on_signal};
        sigaction(numbers[i], &action, NULL);
    }

    int stdin_open = 1;
    size_t capacity = 1 << 16, used = 0;
    char *buffer = malloc(capacity);
    unsigned char chunk[1 << 16];
    for (;;) {
        struct pollfd fds[3] = {{sock, POLLIN, 0}, {wake[0], POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
        if (poll(fds, stdin_open ? 3 : 2, -1) < 0) {
            if (errno == EINTR) continue;
            return 1;
        }
        if (fds[1].revents) {
            read(wake[0], chunk, sizeof chunk);
            for (int number = 1; number < 32; number++) {
                if (!received[number]) continue;
                received[number] = 0;
                char line[16];
                put(line, (size_t)snprintf(line, sizeof line, "s %d\n", number));
            }
        }
        if (fds[0].revents) {
            ssize_t n = read(sock, chunk, sizeof chunk);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return 0;
            if (used + (size_t)n + 1 > capacity) {
                while (used + (size_t)n + 1 > capacity) capacity *= 2;
                buffer = realloc(buffer, capacity);
            }
            memcpy(buffer + used, chunk, (size_t)n);
            used += (size_t)n;
            char *start = buffer, *newline;
            while ((newline = memchr(start, '\n', used - (size_t)(start - buffer)))) {
                *newline = 0;
                handle(start);
                start = newline + 1;
            }
            used -= (size_t)(start - buffer);
            memmove(buffer, start, used);
        }
        if (stdin_open && fds[2].revents) {
            ssize_t n = read(STDIN_FILENO, chunk, sizeof chunk);
            if (n < 0 && errno == EINTR) continue;
            if (n > 0) {
                put_b64("i ", chunk, (size_t)n);
            } else {
                put("e\n", 2);
                stdin_open = 0;
            }
        }
    }
}
