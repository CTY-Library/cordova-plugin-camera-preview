package com.cordovaplugincamerapreview;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.pm.ActivityInfo;
import android.app.Fragment;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Bitmap.CompressFormat;
import android.media.AudioManager;
import android.util.Base64;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.ImageFormat;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.YuvImage;
import android.graphics.drawable.GradientDrawable;
import android.hardware.Camera;
import android.hardware.Camera.PictureCallback;
import android.hardware.Camera.ShutterCallback;
import android.media.CamcorderProfile;
import android.media.MediaRecorder;
import android.os.Bundle;
import android.os.Handler;
import android.util.Log;
import android.util.TypedValue;
import android.util.DisplayMetrics;
import android.util.Size;
import android.view.GestureDetector;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;
import android.widget.FrameLayout;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.RelativeLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import androidx.exifinterface.media.ExifInterface;

import org.apache.cordova.LOG;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.lang.Exception;
import java.lang.Integer;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Arrays;
import java.util.UUID;

public class CameraActivity extends Fragment {
  private static final int GRID_STYLE_OFF = 0;
  private static final int GRID_STYLE_THIRDS = 1;
  private static final int GRID_STYLE_RICE = 2;
  private static final String RATIO_FULL = "full";

  public interface CameraPreviewListener {
    void onPictureTaken(String originalPicture);
    void onPictureTakenError(String message);
    void onSnapshotTaken(String originalPicture);
    void onSnapshotTakenError(String message);
    void onFocusSet(int pointX, int pointY);
    void onFocusSetError(String message);
    void onBackButton();
    void onCameraStarted();
    void onStartRecordVideo();
    void onStartRecordVideoError(String message);
    void onStopRecordVideo(String file);
    void onStopRecordVideoError(String error);
  }

  private CameraPreviewListener eventListener;
  private static final String TAG = "CameraActivity";
  public FrameLayout mainLayout;
  public FrameLayout frameContainerLayout;

  private Preview mPreview;
  private boolean canTakePicture = true;

  private View view;
  private Camera.Parameters cameraParameters;
  private Camera mCamera;
  private int numberOfCameras;
  private int cameraCurrentlyLocked;
  private int currentQuality;
  private String desiredPictureRatio = RATIO_FULL;
  private int gridStyleMode = GRID_STYLE_OFF;
  private int captureDelaySeconds = 0;
  private GridOverlayView gridOverlayView;

  // The first rear facing camera
  private int defaultCameraId;
  public String defaultCamera;

  public boolean tapToTakePicture;
  public boolean dragEnabled;
  public boolean tapToFocus;
  public boolean disableExifHeaderStripping;
  public boolean storeToFile;
  public boolean enableAutoSettings;
  public boolean toBack;

  public int width;
  public int height;
  public int x;
  public int y;

  private enum RecordingState {INITIALIZING, STARTED, STOPPED}

  private RecordingState mRecordingState = RecordingState.INITIALIZING;
  private MediaRecorder mRecorder = null;
  private String recordFilePath;

  public void setEventListener(CameraPreviewListener listener){
    eventListener = listener;
  }

  private String appResourcesPackage;

  @Override
  public View onCreateView(LayoutInflater inflater, ViewGroup container, Bundle savedInstanceState) {
    appResourcesPackage = getActivity().getPackageName();

    // Inflate the layout for this fragment
    view = inflater.inflate(getResources().getIdentifier("camera_activity", "layout", appResourcesPackage), container, false);
    // make fragment root view transparent so container background color is visible
    try {
      view.setBackgroundColor(Color.TRANSPARENT);
    } catch (Exception e) {
      Log.w(TAG, "Could not set fragment root background to transparent", e);
    }
    createCameraPreview();
    return view;
  }

  public void setRect(int x, int y, int width, int height){
    this.x = x;
    this.y = y;
    this.width = width;
    this.height = height;
  }

  public void setDesiredPictureRatio(final String ratio) {
    this.desiredPictureRatio = ratio;
    if (frameContainerLayout != null) {
      applyDesiredRatioToPreviewLayout(frameContainerLayout.getWidth(), frameContainerLayout.getHeight());
      if (gridOverlayView != null) {
        gridOverlayView.invalidate();
      }
    }
  }

  public void setCaptureDelaySeconds(final int seconds) {
    this.captureDelaySeconds = Math.max(0, seconds);
  }

  public void updatePreviewPosition(final int px, final int py) {
    this.x = px;
    this.y = py;
    if (frameContainerLayout != null) {
      final FrameLayout fcl = frameContainerLayout;
      final int left = px;
      final int top = py;
      getActivity().runOnUiThread(new Runnable() {
        @Override
        public void run() {
          try {
            FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) fcl.getLayoutParams();
            lp.leftMargin = left;
            lp.topMargin = top;
            fcl.setLayoutParams(lp);
          } catch (Exception e) {
            Log.e(TAG, "updatePreviewPosition failed", e);
          }
        }
      });
    }
  }

  private void createCameraPreview(){
    if(mPreview == null) {
      setDefaultCameraId();

      //set box position and size
      FrameLayout.LayoutParams layoutParams = new FrameLayout.LayoutParams(width, height);
      layoutParams.setMargins(x, y, 0, 0);
      frameContainerLayout = (FrameLayout) view.findViewById(getResources().getIdentifier("frame_container", "id", appResourcesPackage));
      frameContainerLayout.setLayoutParams(layoutParams);

      //video view
      mPreview = new Preview(getActivity());
      mainLayout = (FrameLayout) view.findViewById(getResources().getIdentifier("video_view", "id", appResourcesPackage));
      mainLayout.setLayoutParams(new RelativeLayout.LayoutParams(RelativeLayout.LayoutParams.MATCH_PARENT, RelativeLayout.LayoutParams.MATCH_PARENT));
      mainLayout.addView(mPreview);

      gridOverlayView = new GridOverlayView(getActivity());
      gridOverlayView.setGridStyleMode(gridStyleMode);
      gridOverlayView.setVisibility(gridStyleMode == GRID_STYLE_OFF ? View.GONE : View.VISIBLE);
      mainLayout.addView(gridOverlayView, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

      applyDesiredRatioToPreviewLayout(width, height);

      mainLayout.setEnabled(false);

      this.setupTouchAndBackButton();

    }
  }

  private void setupTouchAndBackButton(){
    final GestureDetector gestureDetector = new GestureDetector(getActivity().getApplicationContext(), new TapGestureDetector());

    getActivity().runOnUiThread(new Runnable() {
      @Override
      public void run() {
        final ImageButton settingsButton = (ImageButton) view.findViewById(getResources().getIdentifier("camera_settings_button", "id", appResourcesPackage));
        if (settingsButton != null) {
          if (enableAutoSettings) {
            settingsButton.setVisibility(View.VISIBLE);

            FrameLayout.LayoutParams settingsLayoutParams = (FrameLayout.LayoutParams) settingsButton.getLayoutParams();
            int extraTopMargin = (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 8f, getResources().getDisplayMetrics());
            settingsLayoutParams.topMargin = Math.max(settingsLayoutParams.topMargin, getStatusBarHeight() + extraTopMargin);
            settingsButton.setLayoutParams(settingsLayoutParams);

            settingsButton.setOnClickListener(new View.OnClickListener() {
              @Override
              public void onClick(View v) {
                showInAppCameraSettingsDialog();
              }
            });
          } else {
            settingsButton.setVisibility(View.GONE);
            settingsButton.setOnClickListener(null);
          }
        }

        frameContainerLayout.setClickable(true);
        frameContainerLayout.setOnTouchListener(new View.OnTouchListener() {

          private int mLastTouchX;
          private int mLastTouchY;
          private int mPosX = 0;
          private int mPosY = 0;

          @Override
          public boolean onTouch(View v, MotionEvent event) {
            FrameLayout.LayoutParams layoutParams = (FrameLayout.LayoutParams) frameContainerLayout.getLayoutParams();


            boolean isSingleTapTouch = gestureDetector.onTouchEvent(event);
            if (event.getAction() != MotionEvent.ACTION_MOVE && isSingleTapTouch) {
              if (tapToTakePicture && tapToFocus) {
                setFocusArea((int) event.getX(0), (int) event.getY(0), new Camera.AutoFocusCallback() {
                  public void onAutoFocus(boolean success, Camera camera) {
                    if (success) {
                      takePicture(0, 0, 85);
                    } else {
                      Log.d(TAG, "onTouch:" + " setFocusArea() did not suceed");
                    }
                  }
                });

              } else if (tapToTakePicture) {
                takePicture(0, 0, 85);

              } else if (tapToFocus) {
                setFocusArea((int) event.getX(0), (int) event.getY(0), new Camera.AutoFocusCallback() {
                  public void onAutoFocus(boolean success, Camera camera) {
                    if (success) {
                      // A callback to JS might make sense here.
                    } else {
                      Log.d(TAG, "onTouch:" + " setFocusArea() did not suceed");
                    }
                  }
                });
              }
              return true;
            } else {
              if (dragEnabled) {
                int x;
                int y;

                switch (event.getAction()) {
                  case MotionEvent.ACTION_DOWN:
                    if (mLastTouchX == 0 || mLastTouchY == 0) {
                      mLastTouchX = (int) event.getRawX() - layoutParams.leftMargin;
                      mLastTouchY = (int) event.getRawY() - layoutParams.topMargin;
                    } else {
                      mLastTouchX = (int) event.getRawX();
                      mLastTouchY = (int) event.getRawY();
                    }
                    break;
                  case MotionEvent.ACTION_MOVE:

                    x = (int) event.getRawX();
                    y = (int) event.getRawY();

                    final float dx = x - mLastTouchX;
                    final float dy = y - mLastTouchY;

                    mPosX += dx;
                    mPosY += dy;

                    layoutParams.leftMargin = mPosX;
                    layoutParams.topMargin = mPosY;

                    frameContainerLayout.setLayoutParams(layoutParams);

                    // Remember this touch position for the next move event
                    mLastTouchX = x;
                    mLastTouchY = y;

                    break;
                  default:
                    break;
                }
              }
            }
            return true;
          }
        });

        frameContainerLayout.setFocusableInTouchMode(true);
        frameContainerLayout.requestFocus();
        frameContainerLayout.setOnKeyListener(new android.view.View.OnKeyListener() {
          @Override
          public boolean onKey(android.view.View v, int keyCode, android.view.KeyEvent event) {
            if (keyCode == android.view.KeyEvent.KEYCODE_BACK) {
              eventListener.onBackButton();
              return true;
            }
            return false;
          }
        });
      }
    });
  }

  private void setDefaultCameraId(){
    // Find the total number of cameras available
    numberOfCameras = Camera.getNumberOfCameras();

    int facing = "front".equals(defaultCamera) ? Camera.CameraInfo.CAMERA_FACING_FRONT : Camera.CameraInfo.CAMERA_FACING_BACK;

    // Find the ID of the default camera
    Camera.CameraInfo cameraInfo = new Camera.CameraInfo();
    for (int i = 0; i < numberOfCameras; i++) {
      Camera.getCameraInfo(i, cameraInfo);
      if (cameraInfo.facing == facing) {
        defaultCameraId = i;
        break;
      }
    }
  }

  @Override
  public void onResume() {
    super.onResume();

    try {
      mCamera = Camera.open(defaultCameraId);

      if (cameraParameters != null) {
        mCamera.setParameters(cameraParameters);
      }

      cameraCurrentlyLocked = defaultCameraId;

      if(mPreview.mPreviewSize == null){
        mPreview.setCamera(mCamera, cameraCurrentlyLocked);
        applyAutoSettingsIfNeeded();

        // Don't immediately call the callback - post it as a delayed action
        // to ensure the listener is properly set up when it's called
        if (eventListener != null) {
          new Handler().post(new Runnable() {
            @Override
            public void run() {
              if (eventListener != null && isAdded() && !isDetached()) {
                eventListener.onCameraStarted();
              }
            }
          });
        }
      } else {
        mPreview.switchCamera(mCamera, cameraCurrentlyLocked);
        applyAutoSettingsIfNeeded();
        mCamera.startPreview();
      }

      Log.d(TAG, "cameraCurrentlyLocked:" + cameraCurrentlyLocked);

      final FrameLayout frameContainerLayout = (FrameLayout) view.findViewById(getResources().getIdentifier("frame_container", "id", appResourcesPackage));

      ViewTreeObserver viewTreeObserver = frameContainerLayout.getViewTreeObserver();

      if (viewTreeObserver.isAlive()) {
        viewTreeObserver.addOnGlobalLayoutListener(new ViewTreeObserver.OnGlobalLayoutListener() {
          @Override
          public void onGlobalLayout() {
            frameContainerLayout.getViewTreeObserver().removeGlobalOnLayoutListener(this);
            frameContainerLayout.measure(View.MeasureSpec.UNSPECIFIED, View.MeasureSpec.UNSPECIFIED);
            Activity activity = getActivity();
            if (isAdded() && activity != null) {
              applyDesiredRatioToPreviewLayout(frameContainerLayout.getWidth(), frameContainerLayout.getHeight());
            }
          }
        });
      }
    } catch (Exception e) {
      Log.e(TAG, "Error in onResume", e);
    }
  }

  @Override
  public void onPause() {
    super.onPause();

    // Because the Camera object is a shared resource, it's very important to release it when the activity is paused.
    if (mCamera != null) {
      setDefaultCameraId();
      mPreview.setCamera(null, -1);
      mCamera.setPreviewCallback(null);
      mCamera.release();
      mCamera = null;
    }

    Activity activity = getActivity();
    muteStream(false, activity);
  }

  public Camera getCamera() {
    return mCamera;
  }

  private int getStatusBarHeight() {
    int resourceId = getResources().getIdentifier("status_bar_height", "dimen", "android");
    if (resourceId > 0) {
      return getResources().getDimensionPixelSize(resourceId);
    }
    return 0;
  }

  private void applyDesiredRatioToPreviewLayout(int containerWidth, int containerHeight) {
    if (view == null || containerWidth <= 0 || containerHeight <= 0) {
      return;
    }

    final RelativeLayout frameCamContainerLayout = (RelativeLayout) view.findViewById(getResources().getIdentifier("frame_camera_cont", "id", appResourcesPackage));
    if (frameCamContainerLayout == null) {
      return;
    }

    float targetRatio = parseRatioValue(desiredPictureRatio);
    if (targetRatio <= 0f) {
      targetRatio = (float) containerWidth / (float) containerHeight;
    }
    int targetWidth = containerWidth;
    int targetHeight = Math.round(targetWidth / targetRatio);

    if (targetHeight > containerHeight) {
      targetHeight = containerHeight;
      targetWidth = Math.round(targetHeight * targetRatio);
    }

    FrameLayout.LayoutParams camViewLayout = new FrameLayout.LayoutParams(targetWidth, targetHeight);
    camViewLayout.gravity = Gravity.CENTER_HORIZONTAL | Gravity.CENTER_VERTICAL;
    frameCamContainerLayout.setLayoutParams(camViewLayout);
  }

  private void applyAutoSettingsIfNeeded() {
    if (!enableAutoSettings) {
      return;
    }

    applyAutoSettings();
  }

  private void applyAutoSettings() {
    if (mCamera == null) {
      return;
    }

    Camera.Parameters params = mCamera.getParameters();

    List<String> supportedFocusModes = params.getSupportedFocusModes();
    if (supportedFocusModes != null) {
      if (supportedFocusModes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE)) {
        params.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);
      } else if (supportedFocusModes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO)) {
        params.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO);
      } else if (supportedFocusModes.contains(Camera.Parameters.FOCUS_MODE_AUTO)) {
        params.setFocusMode(Camera.Parameters.FOCUS_MODE_AUTO);
      }
    }

    if (params.isAutoExposureLockSupported()) {
      params.setAutoExposureLock(false);
    }

    List<String> supportedWhiteBalanceModes = params.getSupportedWhiteBalance();
    if (supportedWhiteBalanceModes != null && supportedWhiteBalanceModes.contains(Camera.Parameters.WHITE_BALANCE_AUTO)) {
      params.setWhiteBalance(Camera.Parameters.WHITE_BALANCE_AUTO);
    }
    if (params.isAutoWhiteBalanceLockSupported()) {
      params.setAutoWhiteBalanceLock(false);
    }

    List<String> supportedFlashModes = params.getSupportedFlashModes();
    if (supportedFlashModes != null && supportedFlashModes.contains(Camera.Parameters.FLASH_MODE_AUTO)) {
      params.setFlashMode(Camera.Parameters.FLASH_MODE_AUTO);
    }

    mCamera.setParameters(params);
    cameraParameters = params;
  }

  private void showInAppCameraSettingsDialog() {
    final Activity activity = getActivity();
    if (activity == null) {
      return;
    }

    final AlertDialog dialog = new AlertDialog.Builder(activity).create();

    ScrollView scrollView = new ScrollView(activity);
    LinearLayout root = new LinearLayout(activity);
    root.setOrientation(LinearLayout.VERTICAL);
    int padding = dp(12);
    root.setPadding(padding, padding, padding, padding);

    GradientDrawable cardBg = new GradientDrawable();
    cardBg.setColor(Color.parseColor("#FAFAFA"));
    cardBg.setCornerRadius(dp(14));
    root.setBackground(cardBg);

    TextView title = new TextView(activity);
    title.setText("相机设置");
    title.setTextColor(Color.parseColor("#1F2937"));
    title.setTextSize(17);
    title.setPadding(0, 0, 0, dp(4));
    root.addView(title);

    TextView subtitle = new TextView(activity);
    subtitle.setText("全部选项集中展示，点击即生效");
    subtitle.setTextColor(Color.parseColor("#6B7280"));
    subtitle.setTextSize(12);
    subtitle.setPadding(0, 0, 0, dp(10));
    root.addView(subtitle);

    final String[] ratioOptions = new String[] {"全屏", "4:3", "16:9", "1:1"};
    int ratioIndex = 0;
    if (!RATIO_FULL.equals(desiredPictureRatio)) {
      for (int i = 1; i < ratioOptions.length; i++) {
        if (ratioOptions[i].equals(desiredPictureRatio)) {
          ratioIndex = i;
          break;
        }
      }
    }
    root.addView(createInlineOptionGroup(activity, "拍照比例", ratioOptions, ratioIndex, new OnInlineOptionSelected() {
      @Override
      public void onSelected(int selectedIndex) {
        if (selectedIndex == 0) {
          desiredPictureRatio = RATIO_FULL;
        } else {
          desiredPictureRatio = ratioOptions[selectedIndex];
        }
        if (frameContainerLayout != null) {
          applyDesiredRatioToPreviewLayout(frameContainerLayout.getWidth(), frameContainerLayout.getHeight());
        }
      }
    }));

    final String[] gridOptions = new String[] {"关闭", "九宫格", "米字格"};
    root.addView(createInlineOptionGroup(activity, "网格样式", gridOptions, gridStyleMode, new OnInlineOptionSelected() {
      @Override
      public void onSelected(int selectedIndex) {
        gridStyleMode = selectedIndex;
        if (gridOverlayView != null) {
          gridOverlayView.setGridStyleMode(gridStyleMode);
          gridOverlayView.setVisibility(gridStyleMode == GRID_STYLE_OFF ? View.GONE : View.VISIBLE);
          gridOverlayView.invalidate();
        }
      }
    }));

    final String[] timerOptions = new String[] {"关闭", "3秒", "5秒"};
    int timerIndex = 0;
    if (captureDelaySeconds == 3) {
      timerIndex = 1;
    } else if (captureDelaySeconds == 5) {
      timerIndex = 2;
    }
    root.addView(createInlineOptionGroup(activity, "计时拍照", timerOptions, timerIndex, new OnInlineOptionSelected() {
      @Override
      public void onSelected(int selectedIndex) {
        if (selectedIndex == 1) {
          captureDelaySeconds = 3;
        } else if (selectedIndex == 2) {
          captureDelaySeconds = 5;
        } else {
          captureDelaySeconds = 0;
        }
      }
    }));

    if (isTiltShiftSupported()) {
      root.addView(createSettingsRow(activity, "移", "移轴", "可用", new View.OnClickListener() {
        @Override
        public void onClick(View v) {
          Toast.makeText(activity, "当前插件暂未接入移轴设置页", Toast.LENGTH_SHORT).show();
        }
      }));
    }

    TextView closeButton = new TextView(activity);
    closeButton.setText("关闭");
    closeButton.setTextColor(Color.WHITE);
    closeButton.setGravity(Gravity.CENTER);
    closeButton.setTextSize(14);
    closeButton.setPadding(0, dp(10), 0, dp(10));
    GradientDrawable closeBg = new GradientDrawable();
    closeBg.setColor(Color.parseColor("#111827"));
    closeBg.setCornerRadius(dp(10));
    closeButton.setBackground(closeBg);
    LinearLayout.LayoutParams closeLp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    closeLp.topMargin = dp(10);
    closeButton.setLayoutParams(closeLp);
    closeButton.setOnClickListener(new View.OnClickListener() {
      @Override
      public void onClick(View v) {
        dialog.dismiss();
      }
    });
    root.addView(closeButton);

    scrollView.addView(root);
    dialog.setView(scrollView);
    dialog.show();
  }

  private interface OnInlineOptionSelected {
    void onSelected(int selectedIndex);
  }

  private View createInlineOptionGroup(Context context, String label, String[] options, int selectedIndex, final OnInlineOptionSelected listener) {
    LinearLayout group = new LinearLayout(context);
    group.setOrientation(LinearLayout.VERTICAL);

    TextView labelView = new TextView(context);
    labelView.setText(label);
    labelView.setTextColor(Color.parseColor("#4B5563"));
    labelView.setTextSize(13);
    labelView.setPadding(dp(2), 0, dp(2), dp(6));
    group.addView(labelView);

    final LinearLayout optionsRow = new LinearLayout(context);
    optionsRow.setOrientation(LinearLayout.HORIZONTAL);
    optionsRow.setBaselineAligned(false);
    group.addView(optionsRow);

    int safeSelectedIndex = Math.max(0, Math.min(selectedIndex, options.length - 1));
    for (int i = 0; i < options.length; i++) {
      final int index = i;
      final TextView chip = createOptionChip(context, options[i], i == safeSelectedIndex);
      chip.setOnClickListener(new View.OnClickListener() {
        @Override
        public void onClick(View v) {
          for (int child = 0; child < optionsRow.getChildCount(); child++) {
            View childView = optionsRow.getChildAt(child);
            if (childView instanceof TextView) {
              updateOptionChipStyle((TextView) childView, child == index);
            }
          }
          if (listener != null) {
            listener.onSelected(index);
          }
        }
      });
      optionsRow.addView(chip);
    }

    LinearLayout.LayoutParams groupLp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    groupLp.bottomMargin = dp(8);
    group.setLayoutParams(groupLp);
    return group;
  }

  private TextView createOptionChip(Context context, String text, boolean selected) {
    TextView chip = new TextView(context);
    chip.setText(text);
    chip.setGravity(Gravity.CENTER);
    chip.setTextSize(12);
    chip.setPadding(dp(10), dp(6), dp(10), dp(6));

    LinearLayout.LayoutParams chipLp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    chipLp.rightMargin = dp(6);
    chip.setLayoutParams(chipLp);

    updateOptionChipStyle(chip, selected);
    return chip;
  }

  private void updateOptionChipStyle(TextView chip, boolean selected) {
    GradientDrawable chipBg = new GradientDrawable();
    chipBg.setCornerRadius(dp(8));
    if (selected) {
      chipBg.setColor(Color.parseColor("#EAF2FF"));
      chipBg.setStroke(dp(1), Color.parseColor("#3B82F6"));
      chip.setTextColor(Color.parseColor("#1D4ED8"));
    } else {
      chipBg.setColor(Color.WHITE);
      chipBg.setStroke(dp(1), Color.parseColor("#E5E7EB"));
      chip.setTextColor(Color.parseColor("#374151"));
    }
    chip.setBackground(chipBg);
  }

  private View createSettingsRow(Context context, String iconText, String label, String value, View.OnClickListener clickListener) {
    LinearLayout row = new LinearLayout(context);
    row.setOrientation(LinearLayout.HORIZONTAL);
    row.setGravity(Gravity.CENTER_VERTICAL);
    row.setPadding(dp(12), dp(12), dp(12), dp(12));

    GradientDrawable rowBg = new GradientDrawable();
    rowBg.setColor(Color.WHITE);
    rowBg.setCornerRadius(dp(10));
    row.setBackground(rowBg);

    TextView iconView = new TextView(context);
    iconView.setText(iconText);
    iconView.setTextColor(Color.parseColor("#1D4ED8"));
    iconView.setTextSize(12);
    iconView.setGravity(Gravity.CENTER);
    GradientDrawable iconBg = new GradientDrawable();
    iconBg.setColor(Color.parseColor("#EAF2FF"));
    iconBg.setCornerRadius(dp(9));
    iconView.setBackground(iconBg);
    LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(dp(18), dp(18));
    iconLp.rightMargin = dp(10);
    iconView.setLayoutParams(iconLp);
    row.addView(iconView);

    TextView labelView = new TextView(context);
    labelView.setText(label);
    labelView.setTextColor(Color.parseColor("#111827"));
    labelView.setTextSize(15);
    LinearLayout.LayoutParams labelLp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    labelView.setLayoutParams(labelLp);
    row.addView(labelView);

    TextView valueView = new TextView(context);
    valueView.setText(value + "  >");
    valueView.setTextColor(Color.parseColor("#6B7280"));
    valueView.setTextSize(13);
    row.addView(valueView);

    LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    rowLp.bottomMargin = dp(8);
    row.setLayoutParams(rowLp);
    row.setOnClickListener(clickListener);
    return row;
  }

  private int dp(int value) {
    return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics());
  }

  private String getGridStyleLabel() {
    if (gridStyleMode == GRID_STYLE_THIRDS) {
      return "九宫格";
    }
    if (gridStyleMode == GRID_STYLE_RICE) {
      return "米字格";
    }
    return "关闭";
  }

  private String getCaptureDelayLabel() {
    if (captureDelaySeconds <= 0) {
      return "关闭";
    }
    return captureDelaySeconds + "秒";
  }

  private String getRatioLabel() {
    if (RATIO_FULL.equals(desiredPictureRatio)) {
      return "全屏";
    }
    return desiredPictureRatio;
  }

  private boolean isTiltShiftSupported() {
    // Keep the gate explicit for future native implementation.
    return false;
  }

  private void showRatioSettingsDialog() {
    final Activity activity = getActivity();
    if (activity == null) {
      return;
    }

    final String[] ratioOptions = new String[] {"全屏", "4:3", "16:9", "1:1"};
    int checkedItem = 0;
    if (!RATIO_FULL.equals(desiredPictureRatio)) {
      for (int i = 1; i < ratioOptions.length; i++) {
        if (ratioOptions[i].equals(desiredPictureRatio)) {
          checkedItem = i;
          break;
        }
      }
    }

    showSelectionCardDialog("拍照比例", "选择预览画面比例", ratioOptions, checkedItem, new OnSelectionApplied() {
      @Override
      public void onApplied(int selectedIndex) {
        if (selectedIndex == 0) {
          desiredPictureRatio = RATIO_FULL;
        } else {
          desiredPictureRatio = ratioOptions[selectedIndex];
        }
        if (frameContainerLayout != null) {
          applyDesiredRatioToPreviewLayout(frameContainerLayout.getWidth(), frameContainerLayout.getHeight());
        }
        Toast.makeText(activity, "已设置拍照比例：" + getRatioLabel(), Toast.LENGTH_SHORT).show();
      }
    });
  }

  private void showGridStyleSettingsDialog() {
    final Activity activity = getActivity();
    if (activity == null) {
      return;
    }

    final String[] gridOptions = new String[] {"关闭", "九宫格", "米字格"};

    showSelectionCardDialog("网格样式", "构图参考线设置", gridOptions, gridStyleMode, new OnSelectionApplied() {
      @Override
      public void onApplied(int selectedIndex) {
        gridStyleMode = selectedIndex;
        if (gridOverlayView != null) {
          gridOverlayView.setGridStyleMode(gridStyleMode);
          gridOverlayView.setVisibility(gridStyleMode == GRID_STYLE_OFF ? View.GONE : View.VISIBLE);
          gridOverlayView.invalidate();
        }
        Toast.makeText(activity, "已设置网格样式：" + getGridStyleLabel(), Toast.LENGTH_SHORT).show();
      }
    });
  }

  private void showCaptureDelaySettingsDialog() {
    final Activity activity = getActivity();
    if (activity == null) {
      return;
    }

    final String[] timerOptions = new String[] {"关闭", "3秒", "5秒"};
    int checkedItem = 0;
    if (captureDelaySeconds == 3) {
      checkedItem = 1;
    } else if (captureDelaySeconds == 5) {
      checkedItem = 2;
    }

    showSelectionCardDialog("计时拍照", "拍照前延时触发", timerOptions, checkedItem, new OnSelectionApplied() {
      @Override
      public void onApplied(int selectedIndex) {
        if (selectedIndex == 1) {
          captureDelaySeconds = 3;
        } else if (selectedIndex == 2) {
          captureDelaySeconds = 5;
        } else {
          captureDelaySeconds = 0;
        }
        Toast.makeText(activity, "已设置计时拍照：" + getCaptureDelayLabel(), Toast.LENGTH_SHORT).show();
      }
    });
  }

  private interface OnSelectionApplied {
    void onApplied(int selectedIndex);
  }

  private void showSelectionCardDialog(String titleText, String subtitleText, String[] options, int checkedItem, final OnSelectionApplied applyCallback) {
    final Activity activity = getActivity();
    if (activity == null) {
      return;
    }

    final AlertDialog dialog = new AlertDialog.Builder(activity).create();
    final int[] selectedIndex = new int[] {checkedItem};

    ScrollView scrollView = new ScrollView(activity);
    LinearLayout root = new LinearLayout(activity);
    root.setOrientation(LinearLayout.VERTICAL);
    int padding = dp(16);
    root.setPadding(padding, padding, padding, padding);

    GradientDrawable cardBg = new GradientDrawable();
    cardBg.setColor(Color.parseColor("#FAFAFA"));
    cardBg.setCornerRadius(dp(16));
    root.setBackground(cardBg);

    TextView title = new TextView(activity);
    title.setText(titleText);
    title.setTextColor(Color.parseColor("#1F2937"));
    title.setTextSize(18);
    title.setPadding(0, 0, 0, dp(6));
    root.addView(title);

    TextView subtitle = new TextView(activity);
    subtitle.setText(subtitleText);
    subtitle.setTextColor(Color.parseColor("#6B7280"));
    subtitle.setTextSize(13);
    subtitle.setPadding(0, 0, 0, dp(12));
    root.addView(subtitle);

    for (int i = 0; i < options.length; i++) {
      root.addView(createSelectionRow(activity, options[i], i == selectedIndex[0], i, selectedIndex));
    }

    LinearLayout actionRow = new LinearLayout(activity);
    actionRow.setOrientation(LinearLayout.HORIZONTAL);
    LinearLayout.LayoutParams actionRowLp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    actionRowLp.topMargin = dp(12);
    actionRow.setLayoutParams(actionRowLp);

    TextView cancelButton = createDialogActionButton(activity, "取消", Color.parseColor("#E5E7EB"), Color.parseColor("#374151"));
    LinearLayout.LayoutParams cancelLp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    cancelLp.rightMargin = dp(6);
    cancelButton.setLayoutParams(cancelLp);
    cancelButton.setOnClickListener(new View.OnClickListener() {
      @Override
      public void onClick(View v) {
        dialog.dismiss();
      }
    });
    actionRow.addView(cancelButton);

    TextView confirmButton = createDialogActionButton(activity, "确定", Color.parseColor("#111827"), Color.WHITE);
    LinearLayout.LayoutParams confirmLp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    confirmButton.setLayoutParams(confirmLp);
    confirmButton.setOnClickListener(new View.OnClickListener() {
      @Override
      public void onClick(View v) {
        dialog.dismiss();
        if (applyCallback != null) {
          applyCallback.onApplied(selectedIndex[0]);
        }
      }
    });
    actionRow.addView(confirmButton);

    root.addView(actionRow);

    scrollView.addView(root);
    dialog.setView(scrollView);
    dialog.show();
  }

  private View createSelectionRow(Context context, String label, boolean selected, final int index, final int[] selectedIndexRef) {
    final LinearLayout row = new LinearLayout(context);
    row.setOrientation(LinearLayout.HORIZONTAL);
    row.setGravity(Gravity.CENTER_VERTICAL);
    row.setPadding(dp(12), dp(12), dp(12), dp(12));

    final GradientDrawable rowBg = new GradientDrawable();
    rowBg.setCornerRadius(dp(10));
    row.setBackground(rowBg);

    final TextView labelView = new TextView(context);
    labelView.setText(label);
    labelView.setTextSize(15);
    LinearLayout.LayoutParams labelLp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    labelView.setLayoutParams(labelLp);
    row.addView(labelView);

    final TextView checkView = new TextView(context);
    checkView.setTextSize(13);
    row.addView(checkView);

    applySelectionRowStyle(rowBg, labelView, checkView, selected);

    LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    rowLp.bottomMargin = dp(8);
    row.setLayoutParams(rowLp);

    row.setOnClickListener(new View.OnClickListener() {
      @Override
      public void onClick(View v) {
        selectedIndexRef[0] = index;
        ViewGroup parent = (ViewGroup) row.getParent();
        if (parent == null) {
          return;
        }
        for (int i = 0; i < parent.getChildCount(); i++) {
          View child = parent.getChildAt(i);
          if (child instanceof LinearLayout && child.getTag() instanceof SelectionRowHolder) {
            SelectionRowHolder holder = (SelectionRowHolder) child.getTag();
            applySelectionRowStyle(holder.background, holder.label, holder.check, holder.optionIndex == index);
          }
        }
      }
    });

    row.setTag(new SelectionRowHolder(rowBg, labelView, checkView, index));
    return row;
  }

  private static class SelectionRowHolder {
    final GradientDrawable background;
    final TextView label;
    final TextView check;
    final int optionIndex;

    SelectionRowHolder(GradientDrawable background, TextView label, TextView check, int optionIndex) {
      this.background = background;
      this.label = label;
      this.check = check;
      this.optionIndex = optionIndex;
    }
  }

  private void applySelectionRowStyle(GradientDrawable background, TextView label, TextView check, boolean selected) {
    if (selected) {
      background.setColor(Color.parseColor("#EAF2FF"));
      background.setStroke(dp(1), Color.parseColor("#3B82F6"));
      label.setTextColor(Color.parseColor("#1D4ED8"));
      check.setTextColor(Color.parseColor("#1D4ED8"));
      check.setText("已选");
    } else {
      background.setColor(Color.WHITE);
      background.setStroke(0, Color.TRANSPARENT);
      label.setTextColor(Color.parseColor("#111827"));
      check.setTextColor(Color.parseColor("#9CA3AF"));
      check.setText("");
    }
  }

  private TextView createDialogActionButton(Context context, String text, int bgColor, int textColor) {
    TextView button = new TextView(context);
    button.setText(text);
    button.setTextColor(textColor);
    button.setGravity(Gravity.CENTER);
    button.setTextSize(14);
    button.setPadding(0, dp(10), 0, dp(10));

    GradientDrawable bg = new GradientDrawable();
    bg.setColor(bgColor);
    bg.setCornerRadius(dp(10));
    button.setBackground(bg);
    return button;
  }

  private float parseRatioValue(String ratio) {
    if (RATIO_FULL.equals(ratio)) {
      return -1f;
    }
    if ("16:9".equals(ratio)) {
      return 16f / 9f;
    }
    if ("1:1".equals(ratio)) {
      return 1f;
    }
    return 4f / 3f;
  }

  private Camera.Size getBestPictureSizeByRatio(List<Camera.Size> supportedSizes, float targetRatio, int requestedWidth, int requestedHeight) {
    Camera.Size bestSize = null;
    double bestScore = Double.MAX_VALUE;

    for (Camera.Size s : supportedSizes) {
      float currentRatio = (float) s.width / (float) s.height;
      double ratioDelta = Math.abs(currentRatio - targetRatio);

      double areaDelta = 0;
      if (requestedWidth > 0 && requestedHeight > 0) {
        areaDelta = Math.abs((requestedWidth * requestedHeight) - (s.width * s.height)) / 1000000.0;
      } else {
        areaDelta = -((double) s.width * (double) s.height) / 1000000.0;
      }

      double score = ratioDelta * 100 + areaDelta;
      if (score < bestScore) {
        bestScore = score;
        bestSize = s;
      }
    }

    return bestSize != null ? bestSize : supportedSizes.get(0);
  }

  public void switchCamera() {
    // Find the total number of cameras available
    numberOfCameras = Camera.getNumberOfCameras();

    // check for availability of multiple cameras
    if (numberOfCameras == 1) {
      //There is only one camera available
    }else{
      Log.d(TAG, "numberOfCameras: " + numberOfCameras);

      // OK, we have multiple cameras. Release this camera -> cameraCurrentlyLocked
      if (mCamera != null) {
        mCamera.stopPreview();
        mPreview.setCamera(null, -1);
        mCamera.release();
        mCamera = null;
      }

      Log.d(TAG, "cameraCurrentlyLocked := " + Integer.toString(cameraCurrentlyLocked));
      try {
        cameraCurrentlyLocked = (cameraCurrentlyLocked + 1) % numberOfCameras;
        Log.d(TAG, "cameraCurrentlyLocked new: " + cameraCurrentlyLocked);
      } catch (Exception exception) {
        Log.d(TAG, exception.getMessage());
      }

      // Acquire the next camera and request Preview to reconfigure parameters.
      mCamera = Camera.open(cameraCurrentlyLocked);

      if (cameraParameters != null) {
        Log.d(TAG, "camera parameter not null");

        // Check for flashMode as well to prevent error on frontward facing camera.
        List<String> supportedFlashModesNewCamera = mCamera.getParameters().getSupportedFlashModes();
        String currentFlashModePreviousCamera = cameraParameters.getFlashMode();
        if (supportedFlashModesNewCamera != null && supportedFlashModesNewCamera.contains(currentFlashModePreviousCamera)) {
          Log.d(TAG, "current flash mode supported on new camera. setting params");
         /* mCamera.setParameters(cameraParameters);
            The line above is disabled because parameters that can actually be changed are different from one device to another. Makes less sense trying to reconfigure them when changing camera device while those settings gan be changed using plugin methods.
         */
        } else {
          Log.d(TAG, "current flash mode NOT supported on new camera");
        }

      } else {
        Log.d(TAG, "camera parameter NULL");
      }

      mPreview.switchCamera(mCamera, cameraCurrentlyLocked);
      applyAutoSettingsIfNeeded();

      mCamera.startPreview();
    }
  }

  public void setCameraParameters(Camera.Parameters params) {
    cameraParameters = params;

    if (mCamera != null && cameraParameters != null) {
      mCamera.setParameters(cameraParameters);
    }
  }

  public Camera.Size setPreviewSize(int width, int height) {
    if (mPreview == null || mCamera == null) {
      return null;
    }

    this.width = width;
    this.height = height;

    if (frameContainerLayout != null) {
      ViewGroup.LayoutParams layoutParams = frameContainerLayout.getLayoutParams();
      if (layoutParams instanceof FrameLayout.LayoutParams) {
        FrameLayout.LayoutParams frameLayoutParams = (FrameLayout.LayoutParams) layoutParams;
        frameLayoutParams.width = width;
        frameLayoutParams.height = height;
        frameContainerLayout.setLayoutParams(frameLayoutParams);
      } else if (layoutParams != null) {
        layoutParams.width = width;
        layoutParams.height = height;
        frameContainerLayout.setLayoutParams(layoutParams);
      }

      applyDesiredRatioToPreviewLayout(width, height);
      frameContainerLayout.requestLayout();
      frameContainerLayout.invalidate();
    }

    Camera.Size appliedSize = mPreview.setRequestedPreviewSize(width, height);
    if (appliedSize != null) {
      cameraParameters = mCamera.getParameters();
    }

    return appliedSize;
  }

  public boolean hasFrontCamera(){
    return getActivity().getApplicationContext().getPackageManager().hasSystemFeature(PackageManager.FEATURE_CAMERA_FRONT);
  }

  public static Bitmap applyMatrix(Bitmap source, Matrix matrix) {
    return Bitmap.createBitmap(source, 0, 0, source.getWidth(), source.getHeight(), matrix, true);
  }

  ShutterCallback shutterCallback = new ShutterCallback(){
    public void onShutter(){
      // do nothing, availabilty of this callback causes default system shutter sound to work
    }
  };

  private static int exifToDegrees(int exifOrientation) {
    if (exifOrientation == ExifInterface.ORIENTATION_ROTATE_90) { return 90; }
    else if (exifOrientation == ExifInterface.ORIENTATION_ROTATE_180) {  return 180; }
    else if (exifOrientation == ExifInterface.ORIENTATION_ROTATE_270) {  return 270; }
    return 0;
  }

  private String getTempDirectoryPath() {
    File cache = null;

    // Use internal storage
    cache = getActivity().getCacheDir();

    // Create the cache directory if it doesn't exist
    cache.mkdirs();
    return cache.getAbsolutePath();
  }

  private String getTempFilePath() {
    return getTempDirectoryPath() + "/cpcp_capture_" + UUID.randomUUID().toString().replace("-", "").substring(0, 8) + ".jpg";
  }

  PictureCallback jpegPictureCallback = new PictureCallback(){
    public void onPictureTaken(byte[] data, Camera arg1){
      Log.d(TAG, "CameraPreview jpegPictureCallback");

      try {
        if (!disableExifHeaderStripping) {
          Matrix matrix = new Matrix();
          if (cameraCurrentlyLocked == Camera.CameraInfo.CAMERA_FACING_FRONT) {
            matrix.preScale(1.0f, -1.0f);
          }

          ExifInterface exifInterface = new ExifInterface(new ByteArrayInputStream(data));
          int rotation = exifInterface.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
          int rotationInDegrees = exifToDegrees(rotation);

          if (rotation != 0f) {
            matrix.preRotate(rotationInDegrees);
          }

          // Check if matrix has changed. In that case, apply matrix and override data
          if (!matrix.isIdentity()) {
            Bitmap bitmap = BitmapFactory.decodeByteArray(data, 0, data.length);
            bitmap = applyMatrix(bitmap, matrix);

            ByteArrayOutputStream outputStream = new ByteArrayOutputStream();
            bitmap.compress(Bitmap.CompressFormat.JPEG, currentQuality, outputStream);
            data = outputStream.toByteArray();
          }
        }

        if (!storeToFile) {
          String encodedImage = Base64.encodeToString(data, Base64.NO_WRAP);

          if (eventListener != null) {
            eventListener.onPictureTaken(encodedImage);
          } else {
            Log.e(TAG, "eventListener is null");
          }
        } else {
          String path = getTempFilePath();
          FileOutputStream out = new FileOutputStream(path);
          out.write(data);
          out.close();
          if (eventListener != null) {
            eventListener.onPictureTaken(path);
          } else {
            Log.e(TAG, "eventListener is null");
          }
        }
        Log.d(TAG, "CameraPreview pictureTakenHandler called back");
      } catch (OutOfMemoryError e) {
        Log.d(TAG, "CameraPreview OutOfMemoryError", e);
        if (eventListener != null) {
          eventListener.onPictureTakenError("Picture too large (memory)");
        }
      } catch (IOException e) {
        Log.d(TAG, "CameraPreview IOException", e);
        if (eventListener != null) {
          eventListener.onPictureTakenError("IO Error when extracting exif");
        }
      } catch (Exception e) {
        Log.d(TAG, "CameraPreview onPictureTaken general exception", e);
      } finally {
        canTakePicture = true;
        if (mCamera != null) {
          try {
            mCamera.startPreview();
          } catch (Exception e) {
            Log.e(TAG, "Error starting preview in callback", e);
          }
        }
      }
    }
  };

  private Camera.Size getOptimalPictureSize(final int width, final int height, final Camera.Size previewSize, final List<Camera.Size> supportedSizes){
    /*
      get the supportedPictureSize that:
      - matches exactly width and height
      - has the closest aspect ratio to the preview aspect ratio
      - has picture.width and picture.height closest to width and height
      - has the highest supported picture width and height up to 2 Megapixel if width == 0 || height == 0
    */
    Camera.Size size = mCamera.new Size(width, height);

    // convert to landscape if necessary
    if (size.width < size.height) {
      int temp = size.width;
      size.width = size.height;
      size.height = temp;
    }

    Camera.Size requestedSize = mCamera.new Size(size.width, size.height);

    double previewAspectRatio  = (double)previewSize.width / (double)previewSize.height;

    if (previewAspectRatio < 1.0) {
      // reset ratio to landscape
      previewAspectRatio = 1.0 / previewAspectRatio;
    }

    Log.d(TAG, "CameraPreview previewAspectRatio " + previewAspectRatio);

    double aspectTolerance = 0.1;
    double bestDifference = Double.MAX_VALUE;

    for (int i = 0; i < supportedSizes.size(); i++) {
      Camera.Size supportedSize = supportedSizes.get(i);

      // Perfect match
      if (supportedSize.equals(requestedSize)) {
        Log.d(TAG, "CameraPreview optimalPictureSize " + supportedSize.width + 'x' + supportedSize.height);
        return supportedSize;
      }

      double difference = Math.abs(previewAspectRatio - ((double)supportedSize.width / (double)supportedSize.height));

      if (difference < bestDifference - aspectTolerance) {
        // better aspectRatio found
        if ((width != 0 && height != 0) || (supportedSize.width * supportedSize.height < 2048 * 1024)) {
          size.width = supportedSize.width;
          size.height = supportedSize.height;
          bestDifference = difference;
        }
      } else if (difference < bestDifference + aspectTolerance) {
        // same aspectRatio found (within tolerance)
        if (width == 0 || height == 0) {
          // set highest supported resolution below 2 Megapixel
          if ((size.width < supportedSize.width) && (supportedSize.width * supportedSize.height < 2048 * 1024)) {
            size.width = supportedSize.width;
            size.height = supportedSize.height;
          }
        } else {
          // check if this pictureSize closer to requested width and height
          if (Math.abs(width * height - supportedSize.width * supportedSize.height) < Math.abs(width * height - size.width * size.height)) {
            size.width = supportedSize.width;
            size.height = supportedSize.height;
          }
        }
      }
    }
    Log.d(TAG, "CameraPreview optimalPictureSize " + size.width + 'x' + size.height);
    return size;
  }

  static byte[] rotateNV21(final byte[] yuv, final int width, final int height, final int rotation){
    if (rotation == 0) return yuv;
    if (rotation % 90 != 0 || rotation < 0 || rotation > 270) {
      throw new IllegalArgumentException("0 <= rotation < 360, rotation % 90 == 0");
    }

    final byte[]  output    = new byte[yuv.length];
    final int     frameSize = width * height;
    final boolean swap      = rotation % 180 != 0;
    final boolean xflip     = rotation % 270 != 0;
    final boolean yflip     = rotation >= 180;

    for (int j = 0; j < height; j++) {
      for (int i = 0; i < width; i++) {
        final int yIn = j * width + i;
        final int uIn = frameSize + (j >> 1) * width + (i & ~1);
        final int vIn = uIn       + 1;

        final int wOut     = swap  ? height              : width;
        final int hOut     = swap  ? width               : height;
        final int iSwapped = swap  ? j                   : i;
        final int jSwapped = swap  ? i                   : j;
        final int iOut     = xflip ? wOut - iSwapped - 1 : iSwapped;
        final int jOut     = yflip ? hOut - jSwapped - 1 : jSwapped;

        final int yOut = jOut * wOut + iOut;
        final int uOut = frameSize + (jOut >> 1) * wOut + (iOut & ~1);
        final int vOut = uOut + 1;

        output[yOut] = (byte)(0xff & yuv[yIn]);
        output[uOut] = (byte)(0xff & yuv[uIn]);
        output[vOut] = (byte)(0xff & yuv[vIn]);
      }
    }
    return output;
  }

  public void takeSnapshot(final int quality) {
    if (mCamera == null) {
      return;
    }
    mCamera.setPreviewCallback(new Camera.PreviewCallback() {
      @Override
      public void onPreviewFrame(byte[] bytes, Camera camera) {
        try {
          Camera.Parameters parameters = camera.getParameters();
          Camera.Size size = parameters.getPreviewSize();
          int orientation = mPreview.getDisplayOrientation();
          if (mPreview.getCameraFacing() == Camera.CameraInfo.CAMERA_FACING_FRONT) {
            bytes = rotateNV21(bytes, size.width, size.height, (360 - orientation) % 360);
          } else {
            bytes = rotateNV21(bytes, size.width, size.height, orientation);
          }
          // switch width/height when rotating 90/270 deg
          Rect rect = orientation == 90 || orientation == 270 ?
            new Rect(0, 0, size.height, size.width) :
            new Rect(0, 0, size.width, size.height);
          YuvImage yuvImage = new YuvImage(bytes, parameters.getPreviewFormat(), rect.width(), rect.height(), null);
          ByteArrayOutputStream byteArrayOutputStream = new ByteArrayOutputStream();
          yuvImage.compressToJpeg(rect, quality, byteArrayOutputStream);
          byte[] data = byteArrayOutputStream.toByteArray();
          byteArrayOutputStream.close();
          eventListener.onSnapshotTaken(Base64.encodeToString(data, Base64.NO_WRAP));
        } catch (IOException e) {
          Log.d(TAG, "CameraPreview IOException");
          eventListener.onSnapshotTakenError("IO Error");
        } finally {

          mCamera.setPreviewCallback(null);
        }
      }
    });
  }

  public void takePicture(final int width, final int height, final int quality){
    Log.d(TAG, "CameraPreview takePicture width: " + width + ", height: " + height + ", quality: " + quality);

    if(mPreview != null) {
      if(!canTakePicture){
        return;
      }

      canTakePicture = false;

      new Thread() {
        public void run() {
          try {
            if (mCamera == null) {
              Log.d(TAG, "Camera is null, cannot take picture");
              canTakePicture = true; // Reset flag if camera is null
              return;
            }

            if (captureDelaySeconds > 0) {
              Activity activity = getActivity();
              if (activity != null) {
                final int delay = captureDelaySeconds;
                activity.runOnUiThread(new Runnable() {
                  @Override
                  public void run() {
                    Toast.makeText(activity, delay + "秒后拍照", Toast.LENGTH_SHORT).show();
                  }
                });
              }
              Thread.sleep(captureDelaySeconds * 1000L);

              if (mCamera == null) {
                canTakePicture = true;
                return;
              }
            }
            
            Camera.Parameters params = mCamera.getParameters();

            float targetRatio = parseRatioValue(desiredPictureRatio);
            if (targetRatio <= 0f) {
              if (frameContainerLayout != null && frameContainerLayout.getWidth() > 0 && frameContainerLayout.getHeight() > 0) {
                targetRatio = (float) frameContainerLayout.getWidth() / (float) frameContainerLayout.getHeight();
              } else if (params.getPreviewSize() != null && params.getPreviewSize().height > 0) {
                targetRatio = (float) params.getPreviewSize().width / (float) params.getPreviewSize().height;
              } else {
                targetRatio = 4f / 3f;
              }
            }
            Camera.Size size = getBestPictureSizeByRatio(params.getSupportedPictureSizes(), targetRatio, width, height);
            params.setPictureSize(size.width, size.height);
            currentQuality = quality;

            if(cameraCurrentlyLocked == Camera.CameraInfo.CAMERA_FACING_FRONT && !storeToFile) {
              // The image will be recompressed in the callback
              params.setJpegQuality(99);
            } else {
              params.setJpegQuality(quality);
            }

            params.setRotation(mPreview.getDisplayOrientation());

            mCamera.setParameters(params);
            mCamera.takePicture(shutterCallback, null, jpegPictureCallback);
          } catch (InterruptedException e) {
            canTakePicture = true;
            Log.e(TAG, "Capture timer interrupted", e);
            Thread.currentThread().interrupt();
          } catch (Exception e) {
            // Reset flag so future attempts can be made
            canTakePicture = true;
            Log.e(TAG, "Error taking picture", e);
          }
        }
      }.start();
    } else {
      canTakePicture = true;
    }
  }

  public void startRecord(final String filePath, final String camera, final int width, final int height, final int quality, final boolean withFlash){
    Log.d(TAG, "CameraPreview startRecord camera: " + camera + " width: " + width + ", height: " + height + ", quality: " + quality);
    if(mCamera != null) {
      Activity activity = getActivity();
      muteStream(true, activity);
      if (this.mRecordingState == RecordingState.STARTED) {
        Log.d(TAG, "Already Recording");
        return;
      }

      this.recordFilePath = filePath;
      int mOrientationHint = calculateOrientationHint();
      int videoWidth = 0;//set whatever
      int videoHeight = 0;//set whatever

      Camera.Parameters cameraParams = mCamera.getParameters();
      if (withFlash) {
        List<String> flashModes = cameraParams.getSupportedFlashModes();

        if (flashModes != null) {
          Log.d(TAG, "Enabling flash on device");

          if (flashModes.contains(Camera.Parameters.FLASH_MODE_TORCH)) {
            cameraParams.setFlashMode(Camera.Parameters.FLASH_MODE_TORCH);
          } else if (flashModes.contains(Camera.Parameters.FLASH_MODE_ON)) {
            cameraParams.setFlashMode(Camera.Parameters.FLASH_MODE_ON);
          } else if (flashModes.contains(Camera.Parameters.FLASH_MODE_AUTO)) {
            cameraParams.setFlashMode(Camera.Parameters.FLASH_MODE_AUTO);
          }
        } else {
          Log.d(TAG, "Flash not supported on device");
        }

        mCamera.setParameters(cameraParams);
        mCamera.startPreview();
      }

      mCamera.unlock();
      mRecorder = new MediaRecorder();

      try {
        mRecorder.setCamera(mCamera);

        CamcorderProfile profile;
        if (CamcorderProfile.hasProfile(defaultCameraId, CamcorderProfile.QUALITY_HIGH)) {
          profile = CamcorderProfile.get(defaultCameraId, CamcorderProfile.QUALITY_HIGH);
        } else {
          if (CamcorderProfile.hasProfile(defaultCameraId, CamcorderProfile.QUALITY_480P)) {
            profile = CamcorderProfile.get(defaultCameraId, CamcorderProfile.QUALITY_480P);
          } else {
            if (CamcorderProfile.hasProfile(defaultCameraId, CamcorderProfile.QUALITY_720P)) {
              profile = CamcorderProfile.get(defaultCameraId, CamcorderProfile.QUALITY_720P);
            } else {
              if (CamcorderProfile.hasProfile(defaultCameraId, CamcorderProfile.QUALITY_1080P)) {
                profile = CamcorderProfile.get(defaultCameraId, CamcorderProfile.QUALITY_1080P);
              } else {
                profile = CamcorderProfile.get(defaultCameraId, CamcorderProfile.QUALITY_LOW);
              }
            }
          }
        }


        mRecorder.setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION);
        mRecorder.setVideoSource(MediaRecorder.VideoSource.CAMERA);
        mRecorder.setProfile(profile);
        mRecorder.setOutputFile(filePath);
        mRecorder.setOrientationHint(mOrientationHint);

        mRecorder.prepare();
        Log.d(TAG, "Starting recording");
        mRecorder.start();
        eventListener.onStartRecordVideo();
      } catch (IOException ioException) {
        Log.e(TAG, "Recording failed, file issue", ioException);
        eventListener.onStartRecordVideoError(ioException.getMessage());

        mRecorder = null;
      } catch (IllegalStateException stateException) {
        Log.e(TAG, "Recording failed, audio/video may be in use by another application", stateException);
        eventListener.onStartRecordVideoError("Failed to start recording, your audio or video may be in use by another application");

        mRecorder = null;
      } catch (Exception exception) {
        Log.e(TAG, "Recording failed, unknown", exception);
        eventListener.onStartRecordVideoError(exception.getMessage());

        mRecorder = null;
      }
    } else {
      Log.d(TAG, "Requiring RECORD_AUDIO permission to continue");
    }
  }

  public int calculateOrientationHint() {
    DisplayMetrics dm = new DisplayMetrics();
    Camera.CameraInfo info = new Camera.CameraInfo();
    Camera.getCameraInfo(defaultCameraId, info);
    int cameraRotationOffset = info.orientation;
    Activity activity = getActivity();

    activity.getWindowManager().getDefaultDisplay().getMetrics(dm);
    int currentScreenRotation = activity.getWindowManager().getDefaultDisplay().getRotation();

    int degrees = 0;
    switch (currentScreenRotation) {
      case Surface.ROTATION_0:
        degrees = 0;
        break;
      case Surface.ROTATION_90:
        degrees = 90;
        break;
      case Surface.ROTATION_180:
        degrees = 180;
        break;
      case Surface.ROTATION_270:
        degrees = 270;
        break;
    }

    int orientation;
    if (info.facing == Camera.CameraInfo.CAMERA_FACING_FRONT) {
      orientation = (cameraRotationOffset + degrees) % 360;
      if (degrees != 0) {
        orientation = (360 - orientation) % 360;
      }
    } else {
      orientation = (cameraRotationOffset - degrees + 360) % 360;
    }
    Log.w(TAG, "************orientationHint ***********= " + orientation);

    return orientation;
  }

  public void stopRecord() {
    Log.d(TAG, "stopRecord");
    try {
      mRecorder.stop();
      mRecorder.reset();   // clear recorder configuration
      mRecorder.release(); // release the recorder object
      mRecorder = null;
      mCamera.lock();
      Camera.Parameters cameraParams = mCamera.getParameters();
      cameraParams.setFlashMode(Camera.Parameters.FLASH_MODE_OFF);
      mCamera.setParameters(cameraParams);
      mCamera.startPreview();
      eventListener.onStopRecordVideo(this.recordFilePath);
    } catch (Exception e) {
      eventListener.onStopRecordVideoError(e.getMessage());
    }
  }

  public void muteStream(boolean mute, Activity activity) {
    AudioManager audioManager = ((AudioManager)activity.getApplicationContext().getSystemService(Context.AUDIO_SERVICE));
    int direction = mute ? audioManager.ADJUST_MUTE : audioManager.ADJUST_UNMUTE;
  }

  public void setFocusArea(final int pointX, final int pointY, final Camera.AutoFocusCallback callback) {
    if (mCamera != null) {
      mCamera.cancelAutoFocus();

      Camera.Parameters parameters = mCamera.getParameters();

      Rect focusRect = calculateTapArea(pointX, pointY);
      parameters.setFocusMode(Camera.Parameters.FOCUS_MODE_AUTO);
      parameters.setFocusAreas(Arrays.asList(new Camera.Area(focusRect, 1000)));

      if (parameters.getMaxNumMeteringAreas() > 0) {
        parameters.setMeteringAreas(Arrays.asList(new Camera.Area(focusRect, 1000)));
      }

      try {
        setCameraParameters(parameters);
        mCamera.autoFocus(callback);
      } catch (Exception e) {
        Log.d(TAG, e.getMessage());
        callback.onAutoFocus(false, this.mCamera);
      }
    }
  }

  private Rect calculateTapArea(float x, float y) {
    if (x < 100) {
      x = 100;
    }
    if (x > width - 100) {
      x = width - 100;
    }
    if (y < 100) {
      y = 100;
    }
    if (y > height - 100) {
      y = height - 100;
    }
    return new Rect(
      Math.round((x - 100) * 2000 / width  - 1000),
      Math.round((y - 100) * 2000 / height - 1000),
      Math.round((x + 100) * 2000 / width  - 1000),
      Math.round((y + 100) * 2000 / height - 1000)
    );
  }

  static Camera.Size getBestResolution(Camera.Parameters cp) {
    List<Camera.Size> sl = cp.getSupportedVideoSizes();

    if (sl == null)
      sl = cp.getSupportedPictureSizes();

    Camera.Size large = sl.get(0);

    for (Camera.Size s : sl) {
      if ((large.height * large.width) < (s.height * s.width)) {
        large = s;
      }
    }

    return large;
  }

  private static class GridOverlayView extends View {
    private final Paint paint;
    private int gridStyleMode = GRID_STYLE_OFF;

    GridOverlayView(Context context) {
      super(context);
      paint = new Paint();
      paint.setColor(Color.WHITE);
      paint.setStrokeWidth(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 1f, getResources().getDisplayMetrics()));
      paint.setAntiAlias(true);
      paint.setAlpha(160);
      setClickable(false);
    }

    void setGridStyleMode(int gridStyleMode) {
      this.gridStyleMode = gridStyleMode;
    }

    @Override
    protected void onDraw(Canvas canvas) {
      super.onDraw(canvas);
      int w = getWidth();
      int h = getHeight();
      if (w <= 0 || h <= 0) {
        return;
      }

      if (gridStyleMode == GRID_STYLE_THIRDS) {
        float oneThirdW = w / 3f;
        float twoThirdW = oneThirdW * 2f;
        float oneThirdH = h / 3f;
        float twoThirdH = oneThirdH * 2f;

        canvas.drawLine(oneThirdW, 0, oneThirdW, h, paint);
        canvas.drawLine(twoThirdW, 0, twoThirdW, h, paint);
        canvas.drawLine(0, oneThirdH, w, oneThirdH, paint);
        canvas.drawLine(0, twoThirdH, w, twoThirdH, paint);
      } else if (gridStyleMode == GRID_STYLE_RICE) {
        canvas.drawLine(w / 2f, 0, w / 2f, h, paint);
        canvas.drawLine(0, h / 2f, w, h / 2f, paint);
        canvas.drawLine(0, 0, w, h, paint);
        canvas.drawLine(w, 0, 0, h, paint);
      }
    }
  }
}
