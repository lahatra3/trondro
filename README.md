# Trondro 🐟
**Trondro** is an ultra-fast and memory-efficient CLI tool written in **Zig**, designed to extract and stream large volumes of data from PostgreSQL directly to a local file.

By combining *PostgreSQL's asynchronous COPY OUT protocol (libpq)* and Linux's high-performance *io_uring asynchronous I/O interface*, Trondro catches data at the source and flushes it to disk without blocking the main execution thread.

Entirely driven by environment variables.

## Prerequisites
- Linux kernel **5.1+** (for full `io_uring` support)
- Zig **version >= 0.16.0**

## Build
Self-contained binary: statically compiled with `musl`

```bash
$ ~ zig build
# Output:
# zig-out/bin/trondro
```

## Configuration

```bash
$ ~ PG_CONN_INFO="host=127.0.0.1 port=5432 dbname=ldf user=lahatra3 password=lahatrad" \
DT_SOURCE="SELECT * FROM public.logs WHERE log_date = CURRENT_DATE" \
DT_SINK="/tmp/today_logs.csv" \
DT_SINK_COL_SEP="|" \
./trondro
```

## Data flow

```mermaid
flowchart LR
    %% Definitions
    db[(PostgreSQL)]
    lib([libpq COPY OUT])
    wrapper[PgCopyOut]
    handler(((io_uring Event Loop)))
    writer[Asynchronous FileWriter]
    disk[[Physical Disk]]

    %% Flow
    db -->|Text Stream| lib
    lib --> wrapper
    wrapper -->|Register Buffers| handler
    handler -->|SQE Write| writer
    writer -->|Direct I/O| disk

    %% Styling
    style db fill: #336791, stroke: #fff, stroke-width: 2px, color: #fff

    style lib fill: #555555, stroke: #fff, stroke-width: 3px

    style wrapper fill: #ec915c, stroke: #fff, stroke-width: 3px, color: #fff

    style handler fill: #ec915c, stroke: #fff, stroke-width: 3px, color: #fff

    style writer fill: #ec915c, stroke: #fff, stroke-width: 3px, color: #fff
    
    style disk fill:#222,stroke:#fff,stroke-width: 2px,color:#fff
```
