@echo off
setlocal

set "REPO=C:\Users\ahad\Desktop\AI-NL-TO-Refined-Gaussian-Splats"
set "RUN_DIR=%REPO%\runs\A0__VPOSTOREVIDEO"
set "LOG=%RUN_DIR%\layer5_7_pipeline.log"
set "DONE=%RUN_DIR%\layer5_7.done"
set "FAIL=%RUN_DIR%\layer5_7.failed"

del "%DONE%" 2>nul
del "%FAIL%" 2>nul

cd /d "%REPO%"
set "PYTHONPATH=upload_to_splat"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"

echo [%date% %time%] Starting resumed Layers 5-7 for A0__VPOSTOREVIDEO > "%LOG%"
echo [%date% %time%] Layer 5: Brush packaging + quality training >> "%LOG%"
python -u -m brush_packaging_layer.run_layer5 --run-dir runs\A0__VPOSTOREVIDEO --brush-bin C:\Users\ahad\Desktop\brush_release\brush_app.exe --preset quality --non-interactive --no-dense-init >> "%LOG%" 2>&1
if errorlevel 1 goto fail

echo [%date% %time%] Layer 6: quality analysis >> "%LOG%"
python -u -m splat_quality_layer.run_layer6 --run-dir runs\A0__VPOSTOREVIDEO >> "%LOG%" 2>&1
if errorlevel 1 goto fail

echo [%date% %time%] Layer 7: AI analysis >> "%LOG%"
python -u -m ai_analysis_layer.run_layer7 --run-dir runs\A0__VPOSTOREVIDEO --yes >> "%LOG%" 2>&1
if errorlevel 1 goto fail

> "%DONE%" echo done
echo [%date% %time%] COMPLETE >> "%LOG%"
exit /b 0

:fail
set "RC=%errorlevel%"
> "%FAIL%" echo failed
echo [%date% %time%] FAILED rc=%RC% >> "%LOG%"
exit /b %RC%
