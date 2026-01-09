# CICS TG Configuration

This directory contains the custom CTG configuration file used by the container.

## ctg.ini

Custom configuration with logging enabled:
- **ConnectionLogging = on** - Logs client connections and disconnections
- **CicsLogging = on** - Logs messages received from CICS servers

## Applying Configuration to Container

The configuration is currently applied to the running container. If you restart or recreate the container, you'll need to reapply it:

```bash
# Copy configuration to container
docker cp config/ctg.ini cics-ctg-container:/var/cicscli/ctg.ini

# Restart container to apply
docker restart cics-ctg-container
```

Or mount it when starting the container by modifying `run-cics-container.sh` to add:
```bash
-v $(pwd)/config/ctg.ini:/var/cicscli/ctg.ini \
```

## Configuration Changes

To modify the configuration:
1. Edit `config/ctg.ini`
2. Copy it to the container: `docker cp config/ctg.ini cics-ctg-container:/var/cicscli/ctg.ini`
3. Restart the container: `docker restart cics-ctg-container`
