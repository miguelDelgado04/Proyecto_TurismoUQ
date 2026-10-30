/* =====================================================================
   PROYECTO INTEGRADOR - BASES DE DATOS II
   TurismoUQ: plataforma de reservas de alojamientos en el Quindío
   ---------------------------------------------------------------------
   Archivo   : 6_disparadores.sql
   Entrega   : 2 - Disparadores
   Requiere  : 2_DDL.sql, 3_cargue_datos.sql y 5_paquete.sql ejecutados
   Motor     : Oracle Database 21c XE
   ---------------------------------------------------------------------
   CONTENIDO
     1. TRG_RESHAB_NO_SOLAPE ... nivel de fila: impide solapes de una
                                 misma habitación (RN3)
     2. TRG_TARIFA_AUDITORIA ... nivel de sentencia: auditoría de
                                 cambios sobre TARIFA
     3. Verificación

   CÓMO EJECUTARLO
   Conectado como TURISMOUQ, ejecutar todo con F5 (Ejecutar script).
   Es re-ejecutable: CREATE OR REPLACE reemplaza la versión anterior.

   SI SE VUELVE A EJECUTAR LA CARGA (3_cargue_datos.sql)
   Desactivar antes los dos disparadores y activarlos al terminar:
     ALTER TRIGGER trg_reshab_no_solape DISABLE;
     ALTER TRIGGER trg_tarifa_auditoria DISABLE;
     ... ejecutar la carga ...
     ALTER TRIGGER trg_reshab_no_solape ENABLE;
     ALTER TRIGGER trg_tarifa_auditoria ENABLE;
   Con ellos activos, la carga revisaría el solape de ~28.000 líneas
   una por una y auditaría las 34.000 tarifas que borra e inserta.

   POR QUÉ LOS DOS SON COMPOUND TRIGGERS
   Los dos problemas que resuelven chocan con una limitación de Oracle:
     - Un disparador de FILA no puede consultar la tabla sobre la que
       está definido mientras la sentencia la modifica (error ORA-04091,
       "tabla mutante"). Para detectar un solape hay que consultar
       justamente RESERVA_HABITACION.
     - Un disparador de SENTENCIA no tiene :OLD ni :NEW, así que por sí
       solo no puede saber el valor anterior y el nuevo de cada tarifa.
   Un compound trigger reúne en un solo objeto secciones de fila y de
   sentencia que comparten variables. La sección de fila recoge los
   datos de cada fila (:OLD, :NEW) y la sección AFTER STATEMENT, que
   se ejecuta cuando la tabla ya terminó de cambiar, hace el trabajo.
   Es la solución documentada por Oracle para estos dos casos.
   ===================================================================== */

SET SERVEROUTPUT ON SIZE UNLIMITED


/* =====================================================================
   1. TRG_RESHAB_NO_SOLAPE                       (disparador de fila, RN3)
   ---------------------------------------------------------------------
   QUÉ IMPIDE
   Que una habitación quede en dos líneas de reservas no canceladas con
   rangos que se crucen. Rangos semiabiertos [checkin, checkout): dos
   líneas se cruzan si  a.checkin < b.checkout  AND  b.checkin < a.checkout,
   así que el día de salida de un huésped puede ser el de llegada de otro.

   CUÁNDO SE DISPARA
   Por cada fila insertada en RESERVA_HABITACION y por cada fila en que
   se cambie la habitación, las fechas o la reserva. Así también se
   detecta mover una línea existente a fechas ocupadas.

   CÓMO FUNCIONA
     AFTER EACH ROW  : guarda la línea nueva o modificada en una
                       colección. No consulta la tabla (evita ORA-04091).
     AFTER STATEMENT : la tabla ya terminó de cambiar; para cada línea
                       guardada busca otra línea de la misma habitación,
                       de una reserva no cancelada, que se cruce. Si la
                       encuentra, lanza -20020 y Oracle deshace TODA la
                       sentencia (ninguna fila queda insertada).
   Como la revisión se hace al final, también detecta dos líneas que se
   cruzan entre sí dentro de un mismo INSERT ... SELECT de varias filas.

   POR QUÉ "NO CANCELADAS" Y NO SOLO "CONFIRMADAS"
   La RN3 del documento habla de reservas confirmadas y pide validar
   otra vez al pasar de pendiente a confirmada. Aquí se aplica una
   versión más estricta: una reserva PENDIENTE ya retiene la habitación.
     - Es lo que hace una plataforma real: mientras el cliente paga, la
       habitación no se le puede vender a otro.
     - Hace innecesaria la segunda validación al confirmar: si nunca
       existen dos líneas no canceladas cruzadas, confirmar una
       pendiente no puede crear un solape.
     - Es la misma regla con la que se generaron los datos (sección
       15.8 de la carga: solapamientos entre reservas no canceladas = 0).
   Las COMPLETADA también cuentan: son estadías que ocurrieron.
   ===================================================================== */

CREATE OR REPLACE TRIGGER trg_reshab_no_solape
  FOR INSERT OR UPDATE OF id_reserva, id_habitacion, fecha_checkin, fecha_checkout
  ON reserva_habitacion
  COMPOUND TRIGGER

  -- Líneas tocadas por la sentencia, recogidas fila por fila.
  TYPE t_linea IS RECORD (
    id_reserva_hab reserva_habitacion.id_reserva_hab%TYPE,
    id_reserva     reserva_habitacion.id_reserva%TYPE,
    id_habitacion  reserva_habitacion.id_habitacion%TYPE,
    fecha_checkin  reserva_habitacion.fecha_checkin%TYPE,
    fecha_checkout reserva_habitacion.fecha_checkout%TYPE
  );  
  TYPE t_lineas IS TABLE OF t_linea INDEX BY PLS_INTEGER;
  g_lineas t_lineas;

  -- -------------------------------------------------------------------
  -- Nivel de fila: solo recoge los valores nuevos de cada fila.
  -- -------------------------------------------------------------------
  AFTER EACH ROW IS
    v_i PLS_INTEGER := g_lineas.COUNT + 1;
  BEGIN
    g_lineas(v_i).id_reserva_hab := :NEW.id_reserva_hab;
    g_lineas(v_i).id_reserva     := :NEW.id_reserva;
    g_lineas(v_i).id_habitacion  := :NEW.id_habitacion;
    g_lineas(v_i).fecha_checkin  := :NEW.fecha_checkin;
    g_lineas(v_i).fecha_checkout := :NEW.fecha_checkout;
  END AFTER EACH ROW;

  -- -------------------------------------------------------------------
  -- Nivel de sentencia: valida cada línea recogida.
  -- -------------------------------------------------------------------
  AFTER STATEMENT IS
    v_estado    reserva.estado%TYPE;
    v_conflicto reserva.id_reserva%TYPE;
  BEGIN
    FOR i IN 1 .. g_lineas.COUNT LOOP

      -- Una línea de una reserva cancelada no ocupa la habitación.
      SELECT estado INTO v_estado
      FROM   reserva
      WHERE  id_reserva = g_lineas(i).id_reserva;

      IF v_estado <> 'CANCELADA' THEN
        SELECT MIN(rh.id_reserva)
        INTO   v_conflicto
        FROM   reserva_habitacion rh
        JOIN   reserva            r ON r.id_reserva = rh.id_reserva
        WHERE  rh.id_habitacion   = g_lineas(i).id_habitacion
        AND    rh.id_reserva_hab <> g_lineas(i).id_reserva_hab
        AND    r.estado          <> 'CANCELADA'
        AND    rh.fecha_checkin   < g_lineas(i).fecha_checkout
        AND    g_lineas(i).fecha_checkin < rh.fecha_checkout;

        IF v_conflicto IS NOT NULL THEN
          RAISE_APPLICATION_ERROR(pkg_turismouq.c_err_solape,
            'Solape: la habitación ' || g_lineas(i).id_habitacion ||
            ' ya está ocupada entre el ' ||
            TO_CHAR(g_lineas(i).fecha_checkin,  'DD/MM/YYYY') || ' y el ' ||
            TO_CHAR(g_lineas(i).fecha_checkout, 'DD/MM/YYYY') ||
            ' por la reserva ' || v_conflicto || '.');
        END IF;
      END IF;

    END LOOP;
  END AFTER STATEMENT;

END trg_reshab_no_solape;
/


/* =====================================================================
   2. TRG_TARIFA_AUDITORIA                (disparador de sentencia)
   ---------------------------------------------------------------------
   QUÉ REGISTRA
   En AUDITORIA_TARIFA, por cada tarifa afectada:
     quién        -> usuario de la sesión de Oracle
     cuándo       -> momento de la sentencia (SYSTIMESTAMP)
     qué          -> INSERT, UPDATE o DELETE e id de la tarifa
     antes/después-> valor_anterior y valor_nuevo
   El CHECK ck_auditoria_valores de la tabla exige que INSERT solo
   tenga valor nuevo, DELETE solo anterior y UPDATE ambos; el
   disparador llena las columnas exactamente así.

   CÓMO FUNCIONA
     BEFORE STATEMENT: fija quién y cuándo una sola vez, de modo que
                       todas las filas de una misma sentencia quedan con
                       la misma marca de tiempo (se reconoce que fueron
                       un solo cambio, por ejemplo "subir 5 % las
                       tarifas de un hotel").
     AFTER EACH ROW  : guarda :OLD y :NEW de cada fila en una colección.
                       Un UPDATE que no cambia el valor no se registra.
     AFTER STATEMENT : inserta toda la colección de una vez con FORALL
                       (un solo viaje al motor SQL, no uno por fila).
   El registro de la auditoría ocurre una vez por sentencia, que es lo
   que pide el enunciado; la sección de fila existe solo porque un
   disparador de sentencia puro no tiene acceso a :OLD y :NEW.

   POR QUÉ EN LA MISMA TRANSACCIÓN
   La auditoría se guarda en la misma transacción que el cambio. Si el
   cambio se deshace con ROLLBACK, su auditoría también, y eso es lo
   correcto: no hay nada que auditar de un cambio que nunca ocurrió.
   (Una transacción autónoma dejaría registros de cambios inexistentes.)
   ===================================================================== */

CREATE OR REPLACE TRIGGER trg_tarifa_auditoria
  FOR INSERT OR UPDATE OF valor_noche OR DELETE
  ON tarifa
  COMPOUND TRIGGER

  TYPE t_cambios IS TABLE OF auditoria_tarifa%ROWTYPE INDEX BY PLS_INTEGER;
  g_cambios t_cambios;
  g_usuario auditoria_tarifa.usuario_bd%TYPE;
  g_momento auditoria_tarifa.fecha_cambio%TYPE;

  -- -------------------------------------------------------------------
  -- Antes de la sentencia: quién y cuándo, una sola vez.
  -- -------------------------------------------------------------------
  BEFORE STATEMENT IS
  BEGIN
    g_usuario := SYS_CONTEXT('USERENV', 'SESSION_USER');
    g_momento := SYSTIMESTAMP;
  END BEFORE STATEMENT;

  -- -------------------------------------------------------------------
  -- Por cada fila: valor anterior y nuevo.
  -- -------------------------------------------------------------------
  AFTER EACH ROW IS
    v_i PLS_INTEGER;
  BEGIN
    -- Un UPDATE que deja el mismo valor no es un cambio: no se registra.
    IF NOT (UPDATING AND :OLD.valor_noche = :NEW.valor_noche) THEN

      v_i := g_cambios.COUNT + 1;
      g_cambios(v_i).usuario_bd   := g_usuario;
      g_cambios(v_i).fecha_cambio := g_momento;

      IF INSERTING THEN
        g_cambios(v_i).id_tarifa      := :NEW.id_tarifa;
        g_cambios(v_i).operacion      := 'INSERT';
        g_cambios(v_i).valor_anterior := NULL;
        g_cambios(v_i).valor_nuevo    := :NEW.valor_noche;
      ELSIF UPDATING THEN
        g_cambios(v_i).id_tarifa      := :NEW.id_tarifa;
        g_cambios(v_i).operacion      := 'UPDATE';
        g_cambios(v_i).valor_anterior := :OLD.valor_noche;
        g_cambios(v_i).valor_nuevo    := :NEW.valor_noche;
      ELSE  -- DELETING
        g_cambios(v_i).id_tarifa      := :OLD.id_tarifa;
        g_cambios(v_i).operacion      := 'DELETE';
        g_cambios(v_i).valor_anterior := :OLD.valor_noche;
        g_cambios(v_i).valor_nuevo    := NULL;
      END IF;

    END IF;
  END AFTER EACH ROW;

  -- -------------------------------------------------------------------
  -- Después de la sentencia: registra todo de una vez.
  -- -------------------------------------------------------------------
  AFTER STATEMENT IS
  BEGIN
    FORALL i IN 1 .. g_cambios.COUNT
      INSERT INTO auditoria_tarifa
             (id_tarifa, operacion, valor_anterior, valor_nuevo, usuario_bd, fecha_cambio)
      VALUES (g_cambios(i).id_tarifa,
              g_cambios(i).operacion,
              g_cambios(i).valor_anterior,
              g_cambios(i).valor_nuevo,
              g_cambios(i).usuario_bd,
              g_cambios(i).fecha_cambio);
  END AFTER STATEMENT;

END trg_tarifa_auditoria;
/


/* =====================================================================
   3. VERIFICACIÓN
   ---------------------------------------------------------------------
   Los dos disparadores deben salir ENABLED y VALID, y la consulta de
   errores no debe devolver filas.
   ===================================================================== */

SELECT t.trigger_name, t.trigger_type, t.triggering_event,
       t.table_name, t.status, o.status AS compilacion
FROM   user_triggers t
JOIN   user_objects  o ON o.object_name = t.trigger_name
                      AND o.object_type = 'TRIGGER'
WHERE  t.trigger_name IN ('TRG_RESHAB_NO_SOLAPE', 'TRG_TARIFA_AUDITORIA')
ORDER  BY t.trigger_name;

SELECT name, line, position, text
FROM   user_errors
WHERE  name IN ('TRG_RESHAB_NO_SOLAPE', 'TRG_TARIFA_AUDITORIA')
ORDER  BY name, sequence;

/* Fin del script de disparadores */
