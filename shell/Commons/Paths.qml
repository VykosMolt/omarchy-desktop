pragma Singleton

import QtQuick
import Quickshell

QtObject {
    readonly property string home: Quickshell.env("HOME")

    function envOr(name, fallback) {
        const value = Quickshell.env(name)
        return value && value.length > 0 ? value : fallback
    }

    readonly property string configHome: envOr("XDG_CONFIG_HOME", home + "/.config")
    readonly property string stateHome:  envOr("XDG_STATE_HOME",  home + "/.local/state")
    readonly property string cacheHome:  envOr("XDG_CACHE_HOME",  home + "/.cache")
    readonly property string dataHome:   envOr("XDG_DATA_HOME",   home + "/.local/share")

    readonly property string omarchyConfig: envOr("OMARCHY_CONFIG_HOME", configHome + "/omarchy")
    readonly property string omarchyState:  envOr("OMARCHY_STATE_HOME",  stateHome + "/omarchy")
    readonly property string omarchyCache:  envOr("OMARCHY_CACHE_HOME",  cacheHome + "/omarchy")
    readonly property string omarchyData:   envOr("OMARCHY_DATA_HOME",   dataHome + "/omarchy")
}
