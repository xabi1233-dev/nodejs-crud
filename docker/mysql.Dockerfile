# MySQL image with the schema baked in.
#
# Why not just bind-mount schema.sql into /docker-entrypoint-initdb.d/?
# Because Docker Desktop runs the daemon inside a VM and only shares certain
# host paths (by default $HOME). A bind mount from an unshared path such as
# /var/www silently appears as an EMPTY DIRECTORY inside the container, and
# MySQL fails with:
#
#   ERROR: Can't initialize batch_readline - may be the input source is a
#   directory or a block device.
#
# Copying the file in at build time sidesteps the whole problem: the build
# context is sent to the daemon by the CLI, so no host path needs sharing.
# It also makes the image self-contained and portable to any machine.

FROM mysql:8.4

# Runs automatically on first start, when the data directory is empty.
COPY schema.sql /docker-entrypoint-initdb.d/01-schema.sql
