/* Distroless entrypoint: no shell available, so config selection by env var
 * happens here. IS_MS_ON=true -> nginx-ms.conf (ModSecurity + CRS enabled).
 * Runs `nginx -t` first so a broken config (including downstream conf.d
 * overrides and ModSecurity rules) fails the container start with a clear
 * message instead of nginx dying without context. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define NGINX "/usr/sbin/nginx"

int main(void) {
    const char *ms = getenv("IS_MS_ON");
    const char *conf = (ms && strcmp(ms, "true") == 0)
        ? "/etc/nginx/nginx-ms.conf"
        : "/etc/nginx/nginx.conf";

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return 1;
    }
    if (pid == 0) {
        execl(NGINX, "nginx", "-t", "-c", conf, (char *)NULL);
        perror("exec nginx -t");
        _exit(1);
    }
    int status;
    if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "entrypoint: nginx configuration test failed (%s)\n", conf);
        return 1;
    }
    fprintf(stderr, "nginx with modsecurity distroless by morningstar-sudo\nstart now\n");
    execl(NGINX, "nginx", "-c", conf, "-g", "daemon off;", (char *)NULL);
    perror("exec nginx");
    return 1;
}
