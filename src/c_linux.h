#include <stdio.h>
#include <sys/socket.h>

#ifndef AGCE_LINUX
#define AGCE_LINUX

ssize_t agce_linux_send_fd(int socket, int fd_to_send);
int agce_linux_recv_fd(int socket);
void agce_linux_perror();

#endif
