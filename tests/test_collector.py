"""Hardware detection checks on simulated /sys trees. Run: python3 tests/test_collector.py"""
import os, sys, tempfile, importlib.util
spec = importlib.util.spec_from_file_location("c", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "collector.py")); c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
def w(p, v):
    os.makedirs(os.path.dirname(p), exist_ok=True); open(p, "w").write(str(v))
t = tempfile.mkdtemp(); h = t + "/hwmon"
# AMD Ryzen, NVMe, drivetemp, a junk sensor, an acpi zone with only crit
w(f"{h}/hwmon0/name","k10temp"); w(f"{h}/hwmon0/temp1_input",62500); w(f"{h}/hwmon0/temp1_label","Tctl"); w(f"{h}/hwmon0/temp3_input",55000); w(f"{h}/hwmon0/temp3_label","Tccd1")
w(f"{h}/hwmon1/name","nvme"); w(f"{h}/hwmon1/temp1_input",44000); w(f"{h}/hwmon1/temp1_label","Composite")
w(f"{h}/hwmon2/name","drivetemp"); w(f"{h}/hwmon2/temp1_input",33000); os.makedirs(f"{h}/hwmon2/device/block/sdc")
w(f"{h}/hwmon3/name","acpitz"); w(f"{h}/hwmon3/temp1_input",27800); w(f"{h}/hwmon3/temp1_crit",105000)
w(f"{h}/hwmon4/name","junk"); w(f"{h}/hwmon4/temp1_input",-273000); w(f"{h}/hwmon4/temp2_input","garbage"); w(f"{h}/hwmon4/temp3_input",511000)
cpus, other, drives = c.read_temps(h)
assert [x["label"] for x in cpus] == ["Tctl","Tccd1"] and cpus[0]["socket"] == 0 and cpus[0]["temp"] == 62.5, cpus
assert drives == {"sdc": 33.0}, drives
assert [x["label"] for x in other] == ["acpitz temp1"] and other[0]["high"] == 105.0, other
# dual Intel, sockets listed out of order, 10 before 9
h2 = t + "/hw2"
for n, s in ((0, 1), (1, 0)):
    os.makedirs(f"{t}/plat/coretemp.{s}"); os.makedirs(f"{h2}/hwmon{n}"); os.symlink(f"{t}/plat/coretemp.{s}", f"{h2}/hwmon{n}/device")
    w(f"{h2}/hwmon{n}/name","coretemp")
    for i, lab in ((1,"Package id"), (9,"Core 7"), (10,"Core 8")):
        w(f"{h2}/hwmon{n}/temp{i}_input",40000+i*1000); w(f"{h2}/hwmon{n}/temp{i}_label",lab); w(f"{h2}/hwmon{n}/temp{i}_max",90000)
cpus, _, _ = c.read_temps(h2)
assert [x["socket"] for x in cpus] == [1,1,1,0,0,0] and [x["label"] for x in cpus[:3]] == ["Package id","Core 7","Core 8"], cpus
# nothing at all, like a VM
assert c.read_temps(t + "/none") == ([], [], {})
# disk discovery skips virtual devices and empty card readers
b = t + "/block"
for d, size in (("sda",1000),("nvme0n1",2000),("loop0",10),("zd0",10),("dm-1",10),("sr0",10),("rbd0",10),("sdb",0)):
    w(f"{b}/{d}/size",size); w(f"{b}/{d}/queue/rotational",1 if d=="sda" else 0)
w(f"{b}/nvme0n1/device/hwmon3/temp1_input",47000)
ds = c.list_disks(b)
assert [d["dev"] for d in ds] == ["nvme0n1","sda"] or [d["dev"] for d in ds] == ["sda","nvme0n1"], ds
assert {d["dev"]: d["nvme"] for d in ds} == {"sda":False,"nvme0n1":True} and {d["dev"]: d["rotational"] for d in ds}["sda"]
assert c.nvme_temp("nvme0n1", b) == 47.0 and c.nvme_temp("sda", b) is None
print("all passed")
