# 5. Read the counters the kernel keeps wide

Date: 2026-08-10
Status: accepted

## Context

The activity panel reports how fast bytes are moving, and alongside it the
lifetime totals the machine itself would quote. The obvious way to enumerate
interfaces is `getifaddrs`, which hands back an `if_data` per link.

`if_data.ifi_ibytes` is 32 bits. Measured, not assumed: the field is four bytes
wide, so a link rolls over every 4 GiB, which under a sustained transfer is
about every 34 seconds. The first version of this code compensated by giving the
rate counter the counter's modulus and reconstructing each roll-over.

That worked for rates and was wrong for totals, in a way that never healed. The
published total was seeded from the raw reading, so it started life as
`lifetime mod 2^32` and only ever advanced by measured deltas afterwards. On
this Mac, `en0` had already crossed 4 GiB outbound: `getifaddrs` reported
684,542,976 bytes sent against a true 4,979,514,727. The panel would have quoted
the smaller number and stood by it for the whole session.

Reconstruction was always compensation for reading a narrow counter when a wide
one exists.

## Decision

Read `if_data64`, which is genuinely 64 bits, and delete the modulus and the
wrap reconstruction along with it.

Of the two ways to reach `if_data64`, take the second:

- `sysctl(NET_RT_IFLIST2)`, the routing socket, is wide but **rounds every byte
  counter down to a multiple of 1024**. Measured at one instant on `en0`:
  1,771,013,120 from the routing socket against 1,771,014,114 from the MIB and
  from `netstat -ib`. It would have fixed the width and broken agreement with
  the tool people check against.
- `net.link.generic.ifdata.<n>.general` (`ifmibdata`) is wide *and* exact, and
  cheaper: 8 microseconds against 21, because the routing socket carries every
  address as well. Aggregate agreement with `netstat -ibn` across all thirteen
  counted interfaces: zero bytes of difference, in and out.

The same walk decides what to count. `ifmibdata` reports `ifi_type` from the
kernel's own view, where a bridge is `IFT_BRIDGE`; `sockaddr_dl.sdl_type`
reported the same bridge as `IFT_ETHER`, which is why the previous version had
to exclude bridges by name prefix. Types replace that guesswork, and 6to4 and
`gif` tunnels are now excluded because of what they are rather than because they
happened to carry a point-to-point flag.

With one counter width, a counter that moves backwards means exactly one thing,
a device that was replaced, and gets exactly one treatment: no rate for that
tick, and a fresh baseline for the next.

## Consequences

- Totals agree with `netstat -ib` to the byte, at any uptime, on the first frame
  and every frame after.
- One code path instead of two, and no parameter whose wrong value would invent
  or lose 2 GiB at a roll-over that no longer happens.
- A layer-2 (TAP-style) VPN interface is `IFT_ETHER` and not point-to-point, so
  its bytes are still counted twice: once on the tunnel and once on the link
  underneath. No public interface says which link carries which, so the code
  says so in a comment rather than implying the exclusion list is complete.
- `ifmd_flags` is an `unsigned int` filled from a signed short, so a down
  interface arrives with its sign extended (`lo0` reads `0xffff8049`). Masked to
  sixteen bits at the read.
