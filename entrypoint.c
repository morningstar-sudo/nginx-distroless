/* Distroless entrypoint: no shell available, so config selection by env var
 * happens here. IS_MS_ON=true -> nginx-ms.conf (ModSecurity + CRS enabled). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    const char *ms = getenv("IS_MS_ON");
    const char *conf = (ms && strcmp(ms, "true") == 0)
        ? "/etc/nginx/nginx-ms.conf"
        : "/etc/nginx/nginx.conf";
    execl("/usr/sbin/nginx", "nginx", "-c", conf, "-g", "daemon off;", (char *)NULL);
    perror("exec nginx");
    return 1;
}
