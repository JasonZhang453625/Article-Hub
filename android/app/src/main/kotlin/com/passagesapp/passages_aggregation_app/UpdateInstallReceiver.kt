package com.passagesapp.passages_aggregation_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log

class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_INSTALL_STATUS) return
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            val confirmationIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }
            confirmationIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (confirmationIntent != null) context.startActivity(confirmationIntent)
            return
        }

        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        if (status == PackageInstaller.STATUS_SUCCESS) {
            Log.i(LOG_TAG, "App update installed successfully")
        } else {
            Log.e(LOG_TAG, "App update failed: status=$status, message=$message")
        }
    }

    companion object {
        const val ACTION_INSTALL_STATUS =
            "com.passagesapp.passages_aggregation_app.UPDATE_INSTALL_STATUS"
        private const val LOG_TAG = "MemoraUpdate"
    }
}
