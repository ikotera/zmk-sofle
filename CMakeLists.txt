if (CONFIG_ZMK_LAYER_REPORT)
  zephyr_library()
  zephyr_library_sources(src/layer_report.c)
  zephyr_include_directories(${APPLICATION_SOURCE_DIR}/include)
  # 設定の保存にかかる時間を計測するため、settings_save_one の呼び出しを layer_report.c で受ける
  zephyr_ld_options(-Wl,--wrap=settings_save_one)
endif()
