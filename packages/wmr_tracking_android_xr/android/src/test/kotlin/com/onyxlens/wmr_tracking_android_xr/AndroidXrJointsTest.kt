package com.onyxlens.wmr_tracking_android_xr

import androidx.xr.arcore.HandJointType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class AndroidXrJointsTest {
    @Test
    fun everyAndroidXrJointMapsToADistinctOpenXrName() {
        val names = HandJointType.values().map { AndroidXrJoints.name(it) }

        assertEquals(26, names.size)
        names.forEach { assertNotNull(it) }
        assertEquals(26, names.toSet().size)
        assertEquals("palm", AndroidXrJoints.name(HandJointType.PALM))
        assertEquals("wrist", AndroidXrJoints.name(HandJointType.WRIST))
        assertEquals("indexTip", AndroidXrJoints.name(HandJointType.INDEX_TIP))
        assertEquals("littleTip", AndroidXrJoints.name(HandJointType.LITTLE_TIP))
    }
}
