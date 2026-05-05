package com.beantechs.intelligentvehiclecontrol;

import com.beantechs.intelligentvehiclecontrol.sdk.IListener;

interface IIntelligentVehicleControlService {
    void request(String action, String key, String value);
    String fetchData(String key);
    String[] fetchDatas(in String[] keys);
    void addListenerKey(String pkg, in String[] keys);
    void registerDataChangedListener(String pkg, IListener listener);
    void unRegisterDataChangedListener(String pkg, IListener listener);
}