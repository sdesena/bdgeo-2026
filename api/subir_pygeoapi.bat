@echo off
call "C:\Users\gus_h\AppData\Local\Programs\OSGeo4W\bin\o4w_env.bat"

set PROJ_LIB=
set PROJ_DATA=
set PATH=%PYTHONHOME%\Scripts;%PATH%

set PYGEOAPI_CONFIG=pygeoapi-config.yml
set PYGEOAPI_OPENAPI=pygeoapi-openapi.yml

pygeoapi openapi generate %PYGEOAPI_CONFIG% --output-file %PYGEOAPI_OPENAPI%
python -m pygeoapi.flask_app > pygeoapi.log 2>&1

pause