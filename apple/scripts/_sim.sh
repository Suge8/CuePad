# shellcheck shell=bash
# 被 xc.sh 与 perf 脚本 source：每种机型固定一小池模拟器（SIM_POOL 台，名为"CuePad <机型> #<号>"），
# 任务从 _lock.sh 领到号（CUEPAD_SIM）；只编译不运行的用 0 号做目标（不开机、不占）。
# 第一次用时新建，开机后一直开着给后来的任务复用（脚本不关）：冷启动一次要 15–30 秒。
#
# 瘦身：开机后停用 SIM_SLIM 里的系统后台服务（Siri、Spotlight、健康、照片分析、遥测等），每台模拟器的进程与内存降到一半以下（iOS 27.0 实测进程 212→103、内存 2.2→0.9 GB），
# 一台 Mac 才开得下多个会话并行的模拟器。清单取自 simslim（github.com/MobAI-App/simslim，MIT）的 profiles.go，去掉了 CuePad 要用的：
# iCloud 与 Apple 账户、推送与商店（同步、通知），小组件与实时活动（chronod、liveactivitiesd，连带 chronod 里地图小组件要的 navd），
# App Intents（linkd，实时活动的按钮）、自然语言与它的资源（naturallanguaged、mobileassetd）。
# PosterBoard（壁纸与锁屏海报）也停：iOS 27.0 模拟器里它的海报库会坏，之后每次开机反复崩溃，每崩一次 Mac 上弹一个"意外退出"。
# 停用记在宿主的 /private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>/ 里，下次开机起效、以后一直有效，simctl erase 也不清；
# 撤回：对每个标签 `launchctl enable system/<标签>` 后重开机，或删掉这台模拟器（下次用时重建）。

SIM_SLIM=(
  com.apple.PosterBoard
  # Siri 与智能
  com.apple.assistant_cdmd com.apple.assistant_service com.apple.siriactionsd com.apple.siriinferenced com.apple.siriknowledged
  com.apple.sirittsd com.apple.siri.context.service com.apple.siri.acousticsignature com.apple.corespeechd com.apple.voiced
  com.apple.voicebankingd com.apple.speechmodeltrainingd com.apple.intelligenceplatformd com.apple.intelligencecontextd
  com.apple.intelligenceflowd com.apple.intelligencetasksd com.apple.generativeexperiencesd com.apple.knowledgeconstructiond
  com.apple.textunderstandingd com.apple.modelcatalogd com.apple.modelmanagerd com.apple.mlhostd com.apple.mlruntimed
  com.apple.suggestd com.apple.parsecd com.apple.parsec-fbf com.apple.proactiveeventtrackerd
  # Spotlight
  com.apple.searchd com.apple.searchtoold com.apple.spotlightknowledged com.apple.spotlightknowledged.updater com.apple.corespotlightservice
  # 邮件、日历、通讯录
  com.apple.email.maild com.apple.exchangesyncd com.apple.dataaccess.dataaccessd com.apple.calaccessd com.apple.remindd
  com.apple.contactsd com.apple.contacts.postersyncd com.apple.peopled
  # Safari 同步与网页服务
  com.apple.SafariBookmarksSyncAgent com.apple.Safari.History com.apple.Safari.passwordbreachd com.apple.Safari.SafeBrowsing.Service
  com.apple.safarifetcherd com.apple.WebBookmarks.webbookmarksd com.apple.webkit.adattributiond com.apple.webkit.webpushd
  com.apple.webprivacyd com.apple.swcd
  # 家人共享与屏幕使用时间
  com.apple.familycircled com.apple.FamilyControlsAgent com.apple.familynotification com.apple.askpermissiond com.apple.asktod
  com.apple.ScreenTimeAgent com.apple.ScreenTimeSettingsAgent com.apple.UsageTrackingAgent
  # 健康、家庭、健身
  com.apple.healthd com.apple.healthappd com.apple.healthcontentd com.apple.healtheventsd com.apple.healthrecordsd
  com.apple.finhealthd com.apple.homed com.apple.homeeventsd com.apple.fitcore com.apple.fitcore.session
  com.apple.fitnesscoachingd com.apple.fitnessintelligenced com.apple.activityawardsd com.apple.activitysharingd
  # 照片与媒体分析
  com.apple.photoanalysisd com.apple.photosface com.apple.mediaanalysisd com.apple.mediaanalysisd.service
  com.apple.mediastream.mstreamd com.apple.medialibraryd com.apple.assetsd com.apple.assetsd.nebulad
  # 新闻、天气、地图、游戏（gamed 不停：XCUITest 起 App 要它）
  com.apple.newsd com.apple.weatherd com.apple.Maps.mapssyncd com.apple.Maps.mapspushd com.apple.Maps.geocorrectiond
  com.apple.maps.destinationd com.apple.MapKit.SnapshotService com.apple.jetpackassetd com.apple.tipsd com.apple.gamesaved
  com.apple.GameController.gamecontrollerd
  # 信息与 FaceTime
  com.apple.identityservicesd com.apple.ids_simd com.apple.imautomatichistorydeletionagent com.apple.imcore.imtransferagent
  com.apple.imdpersistence.IMDPersistenceAgent com.apple.facetimemessagestored com.apple.telephonyutilities.callservicesd
  # 互联（sharingd 不停：系统分享面板要它）
  com.apple.rapportd com.apple.companiond com.apple.carkitd com.apple.wcd com.apple.tvremoted com.apple.avatarsd
  com.apple.stickersd com.apple.sociallayerd com.apple.announced com.apple.findmy.findmylocated
  # 广告、诊断与遥测
  com.apple.ap.adprivacyd com.apple.ap.promotedcontentd com.apple.diagnosticextensionsd com.apple.feedbackd com.apple.rtcreportingd
  com.apple.securityuploadd com.apple.geoanalyticsd com.apple.triald com.apple.followupd com.apple.purplebuddy.budd com.apple.devicecheckd
  # 其他
  com.apple.merchantd com.apple.coreidvd com.apple.businessservicesd com.apple.deviceaccessd com.apple.replicatord com.apple.ind
  com.apple.storagedatad com.apple.StatusKitAgent com.apple.countryd com.apple.managedconfiguration.passcodenagd
)

# sim_udid <机型>：输出领到的这台（没领就 0 号）的 UDID，没有就建（只建不开机）。
sim_udid() {
  local name="CuePad $1 #${CUEPAD_SIM:-0}" udid
  udid="$(xcrun simctl list devices -j | jq -r --arg n "$name" 'first(.devices[][] | select(.name == $n and .isAvailable) | .udid) // empty')"
  [ -n "$udid" ] || udid="$(xcrun simctl create "$name" "$1")"
  echo "$udid"
}

# sim_unslimmed <UDID>：清单里在这台开着的模拟器上还没停用的标签，一行一个。
sim_unslimmed() {
  comm -23 <(printf '%s\n' "${SIM_SLIM[@]}" | sort) \
    <(xcrun simctl spawn "$1" launchctl print-disabled system | sed -En 's/^[[:space:]]*"(.*)" => (true|disabled)$/\1/p' | sort)
}

# sim_boot <UDID>：开机（已开着就只等系统起好）并确保瘦身：清单里还有没停用的就停用、重开一次机让它生效。
# 新设备与改了清单后的第一次多花一次重开机（约 20 秒），之后每次只多一次 print-disabled。
sim_boot() {
  xcrun simctl bootstatus "$1" -b >/dev/null
  local missing
  missing="$(sim_unslimmed "$1")"
  [ -n "$missing" ] || return 0
  # 停用 agent 时 launchctl 总在 stderr 提一句改用 user/foreground 域，停用照样生效；是否生效以重开机后再查为准
  xargs -P 8 -I {} xcrun simctl spawn "$1" launchctl disable system/{} <<<"$missing" 2>/dev/null
  xcrun simctl shutdown "$1"
  xcrun simctl bootstatus "$1" -b >/dev/null
  missing="$(sim_unslimmed "$1")"
  [ -z "$missing" ] || { echo "模拟器 $1 有服务停用没生效：$missing" >&2; return 1; }
}
