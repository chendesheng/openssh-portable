#!/usr/bin/env python3
"""Exercise actual spawn code with Win32 API doubles; Windows integration is separate."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
COMPAT = ROOT / 'contrib/win32/win32compat'
spawn = (COMPAT / 'spawn-ext.c').read_text()
spawn = spawn[spawn.index('static int\nis_current_process_token'):]
misc = (COMPAT / 'misc.c').read_text()
start = misc.index('int\nw32_current_user_only')
end = misc.index('/*\n * Returns SID of user/group.', start)
helpers = misc[start:end]

api = r'''
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
typedef void *HANDLE;
typedef void *PSID;
typedef unsigned long DWORD;
typedef int BOOLEAN;
typedef struct { unsigned long LowPart; long HighPart; } LUID;
typedef struct { LUID TokenId; int TokenType; } TOKEN_STATISTICS;
typedef int posix_spawn_file_actions_t;
typedef int posix_spawnattr_t;
#define HT(n) ((HANDLE)(intptr_t)(n))
#define TRUE 1
#define FALSE 0
#define TOKEN_QUERY 8
#define TOKEN_IMPERSONATE 4
#define TOKEN_DUPLICATE 2
#define TokenStatistics 10
#define TokenPrimary 1
#define EOTHER EIO
static const char *mode = "1";
static int system_account, open_fails, query_fails, lookup_fails;
static int spawn_calls, load_calls, close_requested, close_probe, spawn_fails;
static HANDLE supplied_token = HT(1), spawned_token;
static BOOLEAN spawned_load_env;
HANDLE password_auth_token, sspi_auth_user;
static DWORD GetEnvironmentVariableA(const char *name, char *value, DWORD size) {
    (void)name;
    size_t length = strlen(mode);
    if (length < size) memcpy(value, mode, length + 1);
    return length < size ? (DWORD)length : (DWORD)length + 1;
}
static HANDLE GetCurrentProcess(void) { return HT(9); }
static int OpenProcessToken(HANDLE process, int rights, HANDLE *token) {
    (void)process; (void)rights;
    if (open_fails) return 0;
    *token = HT(11); return 1;
}
static int GetTokenInformation(HANDLE token, int kind, void *buffer, DWORD size, DWORD *needed) {
    (void)kind; (void)size; (void)needed;
    if (query_fails) return 0;
    TOKEN_STATISTICS *info = buffer;
    info->TokenType = token == HT(3) ? 2 : TokenPrimary;
    info->TokenId.LowPart = token == HT(2) ? 18 : 17;
    info->TokenId.HighPart = token == HT(4) ? 4 : 3;
    return 1;
}
static void CloseHandle(HANDLE token) {
    if (token == HT(11)) close_probe++;
    else close_requested++;
}
static int am_system(void) { return system_account; }
static PSID get_sid(const char *user) {
    if (lookup_fails) return NULL;
    int *sid = malloc(sizeof(*sid));
    *sid = user == NULL || strcmp(user, "owner") == 0 || strcmp(user, "HOST/OWNER") == 0 ? 99 : 100;
    return sid;
}
static int EqualSid(PSID left, PSID right) { return *(int *)left == *(int *)right; }
static HANDLE get_user_token(char *user, int impersonation) {
    (void)user; (void)impersonation; return supplied_token;
}
static HANDLE load_user_profile(HANDLE token, char *user) {
    (void)token; (void)user; load_calls++; return NULL;
}
static void unload_user_profile(HANDLE token, HANDLE profile) { (void)token; (void)profile; }
static int DuplicateHandle(HANDLE a, HANDLE b, HANDLE c, HANDLE *d, int e, int f, int g) {
    (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; return 0;
}
static int GetLastError(void) { return 5; }
static int register_child_profile(pid_t pid, HANDLE profile, HANDLE token) {
    (void)pid; (void)profile; (void)token; return 0;
}
static void error(const char *format, ...) { (void)format; }
static void debug3(const char *format, ...) { (void)format; }
static int posix_spawn_internal(pid_t *pid, const char *path,
    const posix_spawn_file_actions_t *actions, const posix_spawnattr_t *attrs,
    char *const argv[], char *const envp[], HANDLE token, BOOLEAN prepend, BOOLEAN load_env) {
    (void)path; (void)actions; (void)attrs; (void)argv; (void)envp; (void)prepend;
    spawn_calls++; spawned_token = token; spawned_load_env = load_env;
    if (spawn_fails) return -1;
    *pid = 42; return 0;
}
'''

cases = r'''
static int launch(pid_t *pid) {
    return __posix_spawn_asuser(pid, "worker", NULL, NULL, NULL, NULL, "owner");
}
static void reset(void) {
    mode = "1"; system_account = open_fails = query_fails = lookup_fails = 0;
    spawn_calls = load_calls = close_requested = close_probe = spawn_fails = 0;
    password_auth_token = sspi_auth_user = NULL;
    supplied_token = HT(1); spawned_token = HT(99);
}
int main(void) {
    pid_t pid;
    reset(); pid = -1;
    assert(launch(&pid) == 0 && pid == 42);
    assert(spawn_calls == 1 && spawned_token == NULL && !spawned_load_env);
    assert(load_calls == 0 && close_requested == 1 && close_probe == 1);
    reset(); mode = ""; pid = -1;
    assert(launch(&pid) == 0 && spawned_token == HT(1) && spawned_load_env);
    assert(load_calls == 1 && close_probe == 0);
    reset(); system_account = 1;
    assert(launch(&pid) == 0 && spawned_token == HT(1) && spawned_load_env);
    for (int token = 2; token <= 4; token++) {
        reset(); supplied_token = HT(token); pid = -1;
        assert(launch(&pid) == -1 && pid == -1 && errno == EACCES);
        assert(spawn_calls == 0 && close_requested == 1 && close_probe == 1);
    }
    reset(); open_fails = 1;
    assert(launch(&pid) == -1 && spawn_calls == 0 && close_requested == 1 && close_probe == 0);
    reset(); query_fails = 1;
    assert(launch(&pid) == -1 && spawn_calls == 0 && close_requested == 1 && close_probe == 1);
    reset(); sspi_auth_user = HT(1);
    assert(launch(&pid) == 0 && sspi_auth_user == HT(1) && close_requested == 0);
    reset(); password_auth_token = HT(1);
    assert(launch(&pid) == 0 && password_auth_token == NULL && close_requested == 1);
    reset(); spawn_fails = 1; pid = -1;
    assert(launch(&pid) == -1 && pid == -1 && close_requested == 1);
    reset(); assert(w32_current_user_only());
    mode = "10"; assert(!w32_current_user_only());
    mode = "true"; assert(!w32_current_user_only());
    mode = ""; assert(!w32_current_user_only());
    reset(); assert(w32_is_current_user("owner"));
    assert(w32_is_current_user("HOST/OWNER"));
    assert(!w32_is_current_user("another-user"));
    lookup_fails = 1; assert(!w32_is_current_user("owner"));
    puts("PASS: current token, opt-in, service path, restricted/different tokens, query failures, ownership and SID guards");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='openssh-spawn-test-') as directory:
    source = Path(directory) / 'test.c'
    binary = Path(directory) / 'test'
    source.write_text(api + helpers + spawn + cases)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra',
                    '-Werror', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
