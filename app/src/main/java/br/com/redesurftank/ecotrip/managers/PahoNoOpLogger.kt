package br.com.redesurftank.ecotrip.managers

import org.eclipse.paho.client.mqttv3.logging.Logger
import java.util.ResourceBundle

class PahoNoOpLogger : Logger {
    override fun initialise(resourceBundle: ResourceBundle?, loggerID: String?, logName: String?) {}
    override fun setResourceName(logContext: String?) {}
    override fun isLoggable(level: Int): Boolean = false

    override fun severe(sc: String?, sm: String?, msg: String?) {}
    override fun severe(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?) {}
    override fun severe(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?, e: Throwable?) {}

    override fun warning(sc: String?, sm: String?, msg: String?) {}
    override fun warning(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?) {}
    override fun warning(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?, e: Throwable?) {}

    override fun info(sc: String?, sm: String?, msg: String?) {}
    override fun info(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?) {}
    override fun info(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?, e: Throwable?) {}

    override fun config(sc: String?, sm: String?, msg: String?) {}
    override fun config(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?) {}
    override fun config(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?, e: Throwable?) {}

    override fun fine(sc: String?, sm: String?, msg: String?) {}
    override fun fine(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?) {}
    override fun fine(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?, e: Throwable?) {}

    override fun finer(sc: String?, sm: String?, msg: String?) {}
    override fun finer(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?) {}
    override fun finer(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?, e: Throwable?) {}

    override fun finest(sc: String?, sm: String?, msg: String?) {}
    override fun finest(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?) {}
    override fun finest(sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?, e: Throwable?) {}

    override fun log(level: Int, sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?, e: Throwable?) {}
    override fun trace(level: Int, sc: String?, sm: String?, msg: String?, inserts: Array<out Any?>?, e: Throwable?) {}
    override fun formatMessage(msg: String?, inserts: Array<out Any?>?): String = msg ?: ""
    override fun dumpTrace() {}
}
