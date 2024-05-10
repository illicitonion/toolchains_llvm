# Copyright 2021 The Bazel Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

SUPPORTED_TARGETS = [("linux", "x86_64"), ("linux", "aarch64"), ("darwin", "x86_64"), ("darwin", "aarch64")]

# Map of tool name to its symlinked name in the tools directory.
# See tool_paths in toolchain/cc_toolchain_config.bzl.
_toolchain_tools = {
    name: name
    for name in [
        "clang-cpp",
        "ld.lld",
        "llvm-ar",
        "llvm-dwp",
        "llvm-profdata",
        "llvm-cov",
        "llvm-nm",
        "llvm-objcopy",
        "llvm-objdump",
        "llvm-strip",
    ]
}

# Extra tools for Darwin.
_toolchain_tools_darwin = {
    # rules_foreign_cc relies on the filename of the linker to set flags.
    # Also see archive_flags in cc_toolchain_config.bzl.
    # https://github.com/bazelbuild/rules_foreign_cc/blob/5547abc63b12c521113208eea0c5d7f66ba494d4/foreign_cc/built_tools/make_build.bzl#L71
    # https://github.com/bazelbuild/rules_foreign_cc/blob/5547abc63b12c521113208eea0c5d7f66ba494d4/foreign_cc/private/cmake_script.bzl#L319
    "llvm-libtool-darwin": "libtool",
}

def exec_os_key(rctx):
    (os, version, arch) = os_version_arch(rctx)
    if version == "":
        return "%s-%s" % (os, arch)
    else:
        return "%s-%s-%s" % (os, version, arch)

_known_distros = [
    "freebsd",
    "suse",
    "ubuntu",
    "arch",
    "manjaro",
    "debian",
    "fedora",
    "centos",
    "amzn",
    "raspbian",
    "pop",
    "rhel",
    "ol",
    "almalinux",
]

def _linux_dist(rctx):
    info = {}
    for line in rctx.read("/etc/os-release").splitlines():
        parts = line.split("=", 1)
        if len(parts) == 1:
            continue
        info[parts[0]] = parts[1]

    distname = info["ID"].strip('\"')

    if distname not in _known_distros and "ID_LIKE" in info:
        for distro in info["ID_LIKE"].strip('\"').split(" "):
            if distro in _known_distros:
                distname = distro
                break

    version = ""
    if "VERSION_ID" in info:
        version = info["VERSION_ID"].strip('"')
    elif "VERSION_CODENAME" in info:
        version = info["VERSION_CODENAME"].strip('"')

    return distname, version

def os_version_arch(rctx):
    _os = os(rctx)
    _arch = arch(rctx)

    if _os == "linux":
        if (rctx.attr.exec_linux_distribution == "") != (rctx.attr.exec_linux_distribution_version == ""):
            fail("Either both or neither of linux_distribution and linux_distribution_version must be set")
        if rctx.attr.exec_linux_distribution and rctx.attr.exec_linux_distribution_version:
            return rctx.attr.exec_linux_distribution, rctx.attr.exec_linux_distribution_version, _arch
        if not rctx.attr.exec_os:
            (distname, version) = _linux_dist(rctx)
            return distname, version, _arch

    return _os, "", _arch

def os(rctx):
    # Less granular host OS name, e.g. linux.

    name = rctx.attr.exec_os
    if name:
        if name in ("linux", "darwin"):
            return name
        else:
            fail("Unsupported value for exec_os: %s" % name)

    name = rctx.os.name
    if name == "linux":
        return "linux"
    elif name == "mac os x":
        return "darwin"
    elif name.startswith("windows"):
        return "windows"
    fail("Unsupported OS: " + name)

def os_bzl(os):
    # Return the OS string as used in bazel platform constraints.
    return {"darwin": "osx", "linux": "linux"}[os]

def arch(rctx):
    arch = rctx.attr.exec_arch
    if arch:
        if arch in ("arm64", "aarch64"):
            return "aarch64"
        elif arch in ("amd64", "x86_64"):
            return "x86_64"
        else:
            fail("Unsupported value for exec_arch: %s" % arch)

    arch = rctx.os.arch
    if arch == "arm64":
        return "aarch64"
    if arch == "amd64":
        return "x86_64"
    return arch

def os_arch_pair(os, arch):
    return "{}-{}".format(os, arch)

_supported_os_arch = [os_arch_pair(os, arch) for (os, arch) in SUPPORTED_TARGETS]

def supported_os_arch_keys():
    return _supported_os_arch

def check_os_arch_keys(keys):
    for k in keys:
        if k and k not in _supported_os_arch:
            fail("Unsupported {{os}}-{{arch}} key: {key}; valid keys are: {keys}".format(
                key = k,
                keys = ", ".join(_supported_os_arch),
            ))

def exec_os_arch_dict_value(rctx, attr_name, debug = False):
    # Gets a value from a dictionary keyed by host OS and arch.
    # Checks for the more specific key, then the less specific,
    # and finally the empty key as fallback.
    # Returns a tuple of the matching key and value.

    d = getattr(rctx.attr, attr_name)
    key1 = exec_os_key(rctx)
    if key1 in d:
        return (key1, d.get(key1))

    key2 = os_arch_pair(os(rctx), arch(rctx))
    if debug:
        print("`%s` attribute missing for key '%s' in repository '%s'; checking with key '%s'" % (attr_name, key1, rctx.name, key2))  # buildifier: disable=print
    if key2 in d:
        return (key2, d.get(key2))

    if debug:
        print("`%s` attribute missing for key '%s' in repository '%s'; checking with key ''" % (attr_name, key2, rctx.name))  # buildifier: disable=print
    return ("", d.get(""))  # Fallback to empty key.

def canonical_dir_path(path):
    if not path.endswith("/"):
        return path + "/"
    return path

def is_absolute_path(val):
    return val and val[0] == "/" and (len(val) == 1 or val[1] != "/")

def pkg_name_from_label(label):
    if label.workspace_name:
        return "@" + label.workspace_name + "//" + label.package
    else:
        return label.package

def pkg_path_from_label(label):
    if label.workspace_root:
        return label.workspace_root + "/" + label.package
    else:
        return label.package

def list_to_string(ls):
    if ls == None:
        return "None"
    return "[{}]".format(", ".join(["\"{}\"".format(d) for d in ls]))

def attr_dict(attr):
    # Returns a mutable dict of attr values from the struct. This is useful to
    # return updated attribute values as return values of repository_rule
    # implementations.

    tuples = []
    for key in dir(attr):
        if not hasattr(attr, key):
            fail("key %s not found in attributes" % key)
        val = getattr(attr, key)

        # Make mutable copies of frozen types.
        typ = type(val)
        if typ == "dict":
            val = dict(val)
        elif typ == "list":
            val = list(val)
        elif typ == "builtin_function_or_method":
            # Functions can not be compared.
            continue

        tuples.append((key, val))

    return dict(tuples)

def toolchain_tools(os):
    tools = dict(_toolchain_tools)
    if os == "darwin":
        tools.update(_toolchain_tools_darwin)
    return tools
