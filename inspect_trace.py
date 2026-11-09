"""Check whether a CPU Profiler recording reproduces periodic UIKit drawing.

Run through `make inspect TRACE=...`, which exports the two XML inputs:
CPU samples identify the expensive stack and its cadence. Signpost intervals
measure the actual UIKit call duration, which sampling alone cannot establish.
"""

import statistics
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
ids = {element.attrib["id"]: element for element in root.iter() if "id" in element.attrib}


def resolve(element, elements_by_id):
    # xctrace defines a value once with an id, then reuses it through ref attributes.
    return elements_by_id[element.attrib["ref"]] if "ref" in element.attrib else element


matches = []
total_cycles = 0
matched_cycles = 0
samples_without_backtrace = 0
for row in root.iter("row"):
    # CPU Profiler weights are CPU cycles, not elapsed time or allocated bytes.
    weight = int(resolve(row.find("cycle-weight"), ids).text)
    total_cycles += weight
    thread = resolve(row.find("thread"), ids).get("fmt", "")
    backtrace_element = row.find("tagged-backtrace")
    if backtrace_element is None:
        # Device recordings can contain a sentinel instead of an available stack.
        # Keep its cycles in the process total, but do not attribute them to UIKit.
        samples_without_backtrace += 1
        continue
    backtrace = resolve(backtrace_element, ids)
    frames = [resolve(frame, ids).get("name", "") for frame in backtrace.findall("frame")]
    if "Main Thread" in thread and all(
        any(needle in frame for frame in frames)
        for needle in ("drawViewHierarchyInRect:", "CGContextDrawImage", "ripc_DrawImage")
    ):
        matches.append(float(resolve(row.find("sample-time"), ids).text) / 1e9)
        matched_cycles += weight

if not matches:
    sys.exit("NOT REPRODUCED: no main-thread drawHierarchy → CGContextDrawImage → ripc_DrawImage samples.")

# Group samples into capture bursts using a 100ms gap. This is a heuristic for
# this reproducer's ~1s period, not a general-purpose call-boundary detector.
# The span of samples within a burst is not the exact UIKit call duration.
bursts = []
for timestamp in sorted(matches):
    if not bursts or timestamp - bursts[-1][-1] > 0.1:
        bursts.append([])
    bursts[-1].append(timestamp)
intervals = [right[0] - left[0] for left, right in zip(bursts, bursts[1:])]
print(f"Samples without backtrace: {samples_without_backtrace}")
print(f"Matching samples: {len(matches)}")
print(f"Matching CPU cycles: {matched_cycles:,} ({100 * matched_cycles / total_cycles:.1f}% of process total)")
print(f"Distinct bursts: {len(bursts)}")
print("Burst starts (seconds): " + ", ".join(f"{burst[0]:.3f}" for burst in bursts))
if len(bursts) < 5:
    sys.exit("NOT VERIFIED: fewer than five bursts. Record for longer.")
median = statistics.median(intervals)
print(f"Burst intervals min/median/max: {min(intervals):.3f} / {median:.3f} / {max(intervals):.3f} seconds")
spans = [(burst[-1] - burst[0]) * 1000 for burst in bursts]
print(f"Median sampled burst span: {statistics.median(spans):.1f} ms (not exact call duration)")
if not 0.9 <= median <= 1.3:
    sys.exit("NOT VERIFIED: cadence differs from the expected roughly once-per-second capture.")
# The nested drawHierarchy signpost excludes bitmap setup and UIImage creation.
# Its timestamps and durations are in nanoseconds, as are the CPU sample times.
signposts = ET.parse(sys.argv[2]).getroot()
signpost_ids = {element.attrib["id"]: element for element in signposts.iter() if "id" in element.attrib}
durations = []
for row in signposts.iter("row"):
    if resolve(row.find("signpost-name"), signpost_ids).text == "drawHierarchy":
        durations.append(float(resolve(row.find("duration"), signpost_ids).text) / 1e6)
if not durations:
    sys.exit("NOT VERIFIED: no drawHierarchy signpost intervals.")
print(f"drawHierarchy signpost duration min/median/max: {min(durations):.1f} / "
      f"{statistics.median(durations):.1f} / {max(durations):.1f} ms")
print("VERIFIED: recurring main-thread UIKit image-drawing stack at roughly one-second intervals.")
