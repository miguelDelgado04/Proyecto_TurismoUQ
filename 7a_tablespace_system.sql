/* =====================================================================
   PROYECTO INTEGRADOR - BASES DE DATOS II
   TurismoUQ: plataforma de reservas de alojamientos en el Quindío
   ---------------------------------------------------------------------
   Archivo   : 7a_tablespace_system.sql
   Entrega   : 2 - Tablespace propio (parte de administrador)
   Ejecutar  : como SYSTEM, conectado a la MISMA base conectable donde
               vive TURISMOUQ (en Oracle XE 21c normalmente el servicio
               XEPDB1, no la raíz XE)
   Siguiente : 7b_historico_vm.sql, como TURISMOUQ
   Motor     : Oracle Database 21c XE
   ---------------------------------------------------------------------
   QUÉ HACE
     1. Verifica que se esté ejecutando como administrador y que
        TURISMOUQ exista en esta base. Si no, se detiene con un mensaje
        que explica qué corregir, sin crear nada.
     2. Crea el tablespace TS_HISTORICO_RESERVAS (si no existe).
     3. Da a TURISMOUQ cuota en el tablespace y los privilegios CREATE
        MATERIALIZED VIEW y CREATE JOB.
     4. Muestra el tablespace y su datafile.

   Todo va en un solo bloque y las vistas de administrador (DBA_...)
   se consultan con SQL dinámico. Así, si alguien lo ejecuta con otro
   usuario, el bloque compila y da un solo error claro en lugar de
   una cadena de errores.

   POR QUÉ UN SCRIPT APARTE
   Crear un tablespace es una operación de administrador (privilegio
   CREATE TABLESPACE), que un usuario de aplicación como TURISMOUQ no
   debe tener. Es la misma separación de funciones que se profundiza
   en la Entrega 3 (seguridad).

   POR QUÉ UN TABLESPACE PROPIO PARA EL HISTÓRICO
   Las reservas cerradas y las vivas se usan de forma muy distinta:

     Reservas vivas (USERS)     y       Histórico (TS_HISTORICO_RESERVAS)
     

   Separarlas en otro tablespace, con su propio datafile, permite:
     1. Controlar el crecimiento: el datafile tiene AUTOEXTEND con tope
        (MAXSIZE) y TURISMOUQ tiene una cuota fija en él, así que el
        histórico no puede llenar el espacio de la operación. En XE
        esto importa: el límite total de datos de usuario es 12 GB.
     2. Respaldar y recuperar por separado: el histórico cambia poco y
        no necesita el mismo ritmo de copias; un periodo cerrado podría
        incluso pasarse a READ ONLY.
     3. Mover el datafile a un disco más barato o más lento sin tocar
        el de la operación.
     4. Repartir la entrada/salida: las lecturas largas de reportes no
        compiten por los mismos archivos que las transacciones.

   UBICACIÓN DEL DATAFILE
   Se crea en la misma carpeta del datafile del tablespace USERS, que
   se averigua en tiempo de ejecución. 
   ===================================================================== */

SET SERVEROUTPUT ON SIZE UNLIMITED

DECLARE
  c_usuario    CONSTANT VARCHAR2(30) := 'TURISMOUQ';
  c_tablespace CONSTANT VARCHAR2(30) := 'TS_HISTORICO_RESERVAS';
  c_archivo    CONSTANT VARCHAR2(60) := 'TS_HISTORICO_RESERVAS01.DBF';
  v_contenedor VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CON_NAME');
  v_es_admin   PLS_INTEGER;
  v_n          PLS_INTEGER;
  v_ref        VARCHAR2(513);
  v_carpeta    VARCHAR2(513);
  v_archivo    VARCHAR2(513);
  v_tam_mb     NUMBER;
  v_max_mb     NUMBER;
BEGIN
  -- 1. Verificaciones -------------------------------------------------
  SELECT COUNT(*) INTO v_es_admin
  FROM   session_privs
  WHERE  privilege = 'CREATE TABLESPACE';

  IF v_es_admin = 0 THEN
    RAISE_APPLICATION_ERROR(-20900,
      'Este script debe ejecutarse como SYSTEM. Está conectado como ' || USER ||
      '. Abra una conexión de SYSTEM al servicio ' || v_contenedor ||
      ' y vuelva a ejecutarlo.');
  END IF;

  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM dba_users WHERE username = :u'
    INTO v_n USING c_usuario;

  IF v_n = 0 THEN
    RAISE_APPLICATION_ERROR(-20901,
      'El usuario ' || c_usuario || ' no existe en ' || v_contenedor ||
      '. Conecte SYSTEM al mismo servicio que usa la conexión de ' || c_usuario ||
      ' (normalmente XEPDB1, no XE).');
  END IF;

  DBMS_OUTPUT.PUT_LINE('Conectado como ' || USER || ' en ' || v_contenedor || '.');

  -- 2. Tablespace -----------------------------------------------------
  EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM dba_tablespaces WHERE tablespace_name = :t'
    INTO v_n USING c_tablespace;

  IF v_n > 0 THEN
    DBMS_OUTPUT.PUT_LINE('El tablespace ' || c_tablespace || ' ya existe; se reutiliza.');
  ELSE
    -- Carpeta del datafile de USERS (sirve con / en Linux y \ en Windows)
    EXECUTE IMMEDIATE
      'SELECT MIN(file_name) FROM dba_data_files WHERE tablespace_name = ''USERS'''
      INTO v_ref;

    v_carpeta := SUBSTR(v_ref, 1, GREATEST(INSTR(v_ref, '/', -1), INSTR(v_ref, '\', -1)));

    EXECUTE IMMEDIATE
      'CREATE TABLESPACE ' || c_tablespace ||
      ' DATAFILE ''' || v_carpeta || c_archivo || '''' ||
      ' SIZE 50M AUTOEXTEND ON NEXT 10M MAXSIZE 500M' ||
      ' EXTENT MANAGEMENT LOCAL SEGMENT SPACE MANAGEMENT AUTO';

    DBMS_OUTPUT.PUT_LINE('Tablespace ' || c_tablespace || ' creado.');
  END IF;

  -- 3. Cuota y privilegios para TURISMOUQ ------------------------------
  --    Cuota de 200 MB: puede crear tablas en el histórico, con límite.
  --    CREATE MATERIALIZED VIEW: para MV_OCUPACION_MENSUAL.
  --    CREATE JOB: para el refresco nocturno con DBMS_SCHEDULER.
  EXECUTE IMMEDIATE 'ALTER USER ' || c_usuario || ' QUOTA 200M ON ' || c_tablespace;
  EXECUTE IMMEDIATE 'GRANT CREATE MATERIALIZED VIEW TO ' || c_usuario;
  EXECUTE IMMEDIATE 'GRANT CREATE JOB TO ' || c_usuario;
  DBMS_OUTPUT.PUT_LINE('Cuota de 200 MB y privilegios otorgados a ' || c_usuario || '.');

  -- 4. Comprobación ---------------------------------------------------
  EXECUTE IMMEDIATE
    'SELECT file_name, ROUND(bytes / 1024 / 1024), ROUND(maxbytes / 1024 / 1024) ' ||
    'FROM dba_data_files WHERE tablespace_name = :t AND ROWNUM = 1'
    INTO v_archivo, v_tam_mb, v_max_mb USING c_tablespace;

  DBMS_OUTPUT.PUT_LINE('Datafile : ' || v_archivo);
  DBMS_OUTPUT.PUT_LINE('Tamaño   : ' || v_tam_mb || ' MB, crece hasta ' || v_max_mb || ' MB');
  DBMS_OUTPUT.PUT_LINE('Listo. Ahora ejecute 7b_historico_vm.sql conectado como ' || c_usuario || '.');
END;
/

/* Fin del script 7a */
