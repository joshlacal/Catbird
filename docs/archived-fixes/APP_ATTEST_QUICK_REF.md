# App Attest Quick Reference Card

## 🚨 Most Common Issue
**"App Attest not working!"**
→ Are you testing on iOS Simulator? **App Attest ONLY works on physical devices!**

## 🎯 Quick Diagnosis (30 seconds)

```bash
# Step 1: Run debug script
./debug_app_attest.sh

# Step 2: Look for these
✅ Bundle ID: blue.catbird
✅ APNS Environment: development
✅ App Attest Environment: development

# Step 3: Build on physical device
# In Xcode: Product > Destination > [Your iPhone]
```

## 📱 In-App Check (60 seconds)

1. Open app on **physical device**
2. Settings > Notifications
3. Scroll to "App Attest Diagnostics"
4. Look for green checkmarks:
   - ✅ Platform: Physical Device
   - ✅ DCAppAttest Support: Supported
   - ✅ OS Version: Compatible
   - ✅ Bundle ID: blue.catbird
   - ✅ Entitlement: Present

## 🔍 Log Messages Decoder

### ✅ GOOD (Everything working)
```
✅ App Attest is supported, proceeding with attestation
✅ App Attest key generated: [KEY]
✅ App Attest attestation successful
✅ Device token successfully registered
```

### ⚠️ EXPECTED (On Simulator)
```
⚠️ App Attest not supported by DCAppAttestService.isSupported
🔍 DEBUG: Running on Simulator: YES
```
**Fix:** Use physical device

### 🔁 AUTO-RECOVER (Transient issue)
```
💡 Stored App Attest state is no longer valid
🔁 Clearing App Attest state and will retry
```
**Fix:** Nothing - app will fix itself

### ❌ NEED ATTENTION
```
❌ App Attest generateKey failed: [ERROR]
🔐 Server rejected App Attest (HTTP 401)
⏸️ Re-attestation circuit breaker triggered
```
**Fix:** Check details in logs, consult testing guide

## 🛠 Quick Fixes

| Problem | Quick Fix |
|---------|-----------|
| "Not supported" error | Use physical device, not Simulator |
| "Invalid key" error | Wait 5 min, app auto-recovers |
| Infinite spinner | Check network, restart app |
| Server 401/428 | Check server logs & config |
| Circuit breaker | Wait 5 minutes, retry |

## 📚 Full Documentation

- **Start here:** `APP_ATTEST_README.md`
- **Testing:** `APP_ATTEST_TESTING_GUIDE.md`
- **Technical:** `APP_ATTEST_DEBUG_ANALYSIS.md`
- **Summary:** `APP_ATTEST_SUMMARY.md`

## ⚡ Emergency Checklist

When nothing works:
- [ ] Am I on a **physical device**? (not Simulator)
- [ ] Is device iOS 14.0 or later?
- [ ] Is network connected?
- [ ] Did I wait 5 minutes after last failure?
- [ ] Are entitlements configured? (run debug script)
- [ ] Is the server reachable and working?

## 🎓 Key Facts

| Fact | Value |
|------|-------|
| Minimum iOS | 14.0 |
| Minimum macOS | 11.0 |
| Works on Simulator? | ❌ NO |
| Works offline? | ❌ NO (needs Apple servers) |
| Auto-recovers from errors? | ✅ YES (most cases) |
| Circuit breaker timeout | 5 minutes |
| Max retry attempts | 3 per 5 min |

## 🧪 Test Before Release

```bash
# 1. Environment check
./debug_app_attest.sh

# 2. Build for device
# Xcode: Product > Run on Physical Device

# 3. Test in app
# Settings > Notifications > Enable

# 4. Verify logs
# Console.app > Filter: "Catbird"

# 5. Check success
# Should see "✅ Device token successfully registered"
```

## 🆘 Getting Help

1. **Read docs** (links above)
2. **Check logs** (Console.app)
3. **Try diagnostics** (in-app tool)
4. **Verify server** (if client looks good)
5. **Check Apple status** (developer.apple.com/system-status)

---
**Remember:** App Attest = Physical Device Only! 📱
