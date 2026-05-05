// IListener.aidl
package com.beantechs.intelligentvehiclecontrol.sdk;

// Declare any non-default types here with import statements

interface IListener {
    void onDataChanged(in String key, in String value);
}