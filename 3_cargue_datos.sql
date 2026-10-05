/* =====================================================================
   PROYECTO INTEGRADOR - BASES DE DATOS II
   TurismoUQ: plataforma de reservas de alojamientos en el Quindío
   ---------------------------------------------------------------------
   Archivo   : 02_CARGA_TurismoUQ.sql
   Entrega   : 1 - Script de carga de datos (volumen mínimo)
   Requiere  : 01_DDL_TurismoUQ.sql ejecutado antes, en el mismo esquema
   Motor     : Oracle Database 21c XE (también corre en 23ai Free)
   ---------------------------------------------------------------------
   QUÉ HACE
   Genera con PL/SQL y DBMS_RANDOM todos los datos del modelo, con el
   volumen mínimo del enunciado (sección 3) y de forma ASIMÉTRICA:
     - Alojamientos repartidos de forma desigual entre municipios.
     - Hoteles grandes con 30-40 habitaciones y fincas con 3-6.
     - Reservas con estacionalidad real (temporada alta, fines de
       semana y crecimiento año a año).
     - Municipios, alojamientos y clientes con popularidad distinta.
     - Calificaciones de reseñas que varían por alojamiento.

   VOLUMEN APROXIMADO QUE GENERA (cambia un poco según la semilla)
     MUNICIPIO 12 | TIPO_ALOJAMIENTO 5 | ROL 5 | USUARIO_SISTEMA 10
     ALOJAMIENTO 60 | HABITACION ~580 | SERVICIO 30
     TIPO_TEMPORADA 3 | TEMPORADA ~59 | TARIFA ~34.000
     CLIENTE 3.000 | RESERVA 25.000 | RESERVA_HABITACION ~28.600
     RESERVA_NOCHE ~80.000 | RESERVA_SERVICIO >= 40.000
     PAGO ~32.000 | CANCELACION ~3.000 | RESENA >= 40 % de completadas

   CÓMO EJECUTARLO
   1. Conectarse como TURISMOUQ (nunca como SYSTEM).
   2. Ejecutar el script COMPLETO con F5 (Ejecutar script). Tarda entre
      2 y 6 minutos según el equipo.
   3. Es re-ejecutable: la sección 0 vacía las tablas antes de cargar.
   4. Al final, la sección 15 muestra las verificaciones de volumen,
      asimetría e integridad.

   FECHA DE CORTE
   Se usa 30/09/2026 (fecha de la Entrega 1) como "hoy" del negocio:
     - Reservas con salida antes del corte: COMPLETADA o CANCELADA.
     - Reservas con llegada después del corte: PENDIENTE, CONFIRMADA o
       CANCELADA.
     - Reservas en curso el día del corte: CONFIRMADA.
   Es una constante y no SYSDATE, para que los datos no cambien según
   el día en que se ejecute el script.

   PERSONALIZACIÓN (IMPORTANTE)
   El enunciado anula dos proyectos con los mismos datos. Antes de
   entregar, cambien:
     - La semilla de DBMS_RANDOM.SEED (sección 0).
     - Los valores de semilla de ORA_HASH (tercer parámetro, marcados
       con el comentario "semilla").
     - Si quieren, los nombres de alojamientos, servicios y clientes.
   ===================================================================== */

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';

/* =====================================================================
   0. PREPARACIÓN
   ===================================================================== */
-- Semilla para el generador aleatorio.
-- Usar la misma semilla genera siempre los mismos datos de prueba.

BEGIN
  DBMS_RANDOM.SEED(48251);
END;
/

-- Vacía las tablas empezando por las dependientes.

-- Se usa DELETE en lugar de TRUNCATE para evitar fallos por relaciones activas entre tablas.
BEGIN
  DELETE FROM liquidacion_mensual;
  DELETE FROM auditoria_tarifa;
  DELETE FROM resena;
  DELETE FROM reserva_servicio;
  DELETE FROM cancelacion;
  DELETE FROM pago;
  DELETE FROM reserva_noche;
  DELETE FROM reserva_habitacion;
  DELETE FROM reserva;
  DELETE FROM cliente;
  DELETE FROM tarifa;
  DELETE FROM temporada;
  DELETE FROM tipo_temporada;
  DELETE FROM servicio;
  DELETE FROM habitacion;
  DELETE FROM alojamiento;
  DELETE FROM usuario_sistema;
  DELETE FROM rol;
  DELETE FROM tipo_alojamiento;
  DELETE FROM municipio;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('0. Tablas vaciadas.');
END;
/

/* =====================================================================
  1. CATÁLOGOS
  Se insertan con ID explícito para referenciarlos en el resto del script.
  Al final se ajustan las columnas autoincrementables para evitar duplicados en futuros INSERT.
   ===================================================================== */

-- Los 12 municipios reales del Quindío (en orden alfabético).

INSERT INTO municipio (id_municipio, nombre) VALUES ( 1, 'Armenia');
INSERT INTO municipio (id_municipio, nombre) VALUES ( 2, 'Buenavista');
INSERT INTO municipio (id_municipio, nombre) VALUES ( 3, 'Calarcá');
INSERT INTO municipio (id_municipio, nombre) VALUES ( 4, 'Circasia');
INSERT INTO municipio (id_municipio, nombre) VALUES ( 5, 'Córdoba');
INSERT INTO municipio (id_municipio, nombre) VALUES ( 6, 'Filandia');
INSERT INTO municipio (id_municipio, nombre) VALUES ( 7, 'Génova');
INSERT INTO municipio (id_municipio, nombre) VALUES ( 8, 'La Tebaida');
INSERT INTO municipio (id_municipio, nombre) VALUES ( 9, 'Montenegro');
INSERT INTO municipio (id_municipio, nombre) VALUES (10, 'Pijao');
INSERT INTO municipio (id_municipio, nombre) VALUES (11, 'Quimbaya');
INSERT INTO municipio (id_municipio, nombre) VALUES (12, 'Salento');

-- Tipos de alojamiento: los 4 del enunciado + CABAÑAS.

INSERT INTO tipo_alojamiento (id_tipo_alojamiento, nombre, descripcion)
  VALUES (1, 'FINCA CAFETERA', 'Finca productora de café adaptada para recibir turistas.');
INSERT INTO tipo_alojamiento (id_tipo_alojamiento, nombre, descripcion)
  VALUES (2, 'HOTEL', 'Establecimiento urbano o campestre con recepción permanente.');
INSERT INTO tipo_alojamiento (id_tipo_alojamiento, nombre, descripcion)
  VALUES (3, 'GLAMPING', 'Alojamiento en domos o carpas con comodidades de hotel.');
INSERT INTO tipo_alojamiento (id_tipo_alojamiento, nombre, descripcion)
  VALUES (4, 'HOSTAL', 'Alojamiento económico orientado a mochileros.');
INSERT INTO tipo_alojamiento (id_tipo_alojamiento, nombre, descripcion)
  VALUES (5, 'CABAÑAS', 'Conjunto de cabañas independientes para familias o grupos.');

-- Roles funcionales (alineados con los roles de Oracle de la Entrega 3).

INSERT INTO rol (id_rol, nombre, descripcion) VALUES (1, 'ADMIN_PLATAFORMA',      'Administra toda la plataforma.');
INSERT INTO rol (id_rol, nombre, descripcion) VALUES (2, 'ENCARGADO_ALOJAMIENTO', 'Gestiona habitaciones, tarifas y reservas de sus alojamientos.');
INSERT INTO rol (id_rol, nombre, descripcion) VALUES (3, 'RECEPCION',             'Registra llegadas, salidas y pagos en recepción.');
INSERT INTO rol (id_rol, nombre, descripcion) VALUES (4, 'GERENTE',               'Consulta informes de ocupación e ingresos.');
INSERT INTO rol (id_rol, nombre, descripcion) VALUES (5, 'AUDITOR',               'Revisa auditorías y cambios de tarifas.');

-- Tipos de temporada.
INSERT INTO tipo_temporada (id_tipo_temporada, nombre) VALUES (1, 'ALTA');
INSERT INTO tipo_temporada (id_tipo_temporada, nombre) VALUES (2, 'MEDIA');
INSERT INTO tipo_temporada (id_tipo_temporada, nombre) VALUES (3, 'BAJA');

COMMIT;


/* =====================================================================
 2. USUARIO_SISTEMA (10)
 Registra usuarios iniciales del sistema: 2 administradores, 1 encargado por cada tipo de alojamiento (5),
 y 1 usuario de recepción, gerencia y auditoría. 
   ===================================================================== */
   
INSERT INTO usuario_sistema (id_usuario, id_rol, usuario_bd, nombre, correo, activo)
  VALUES ( 1, 1, 'TQ_ADMIN1',       'Laura Gómez Restrepo',     'laura.gomez@turismouq.co',     'S');
INSERT INTO usuario_sistema (id_usuario, id_rol, usuario_bd, nombre, correo, activo)
  VALUES ( 2, 1, 'TQ_ADMIN2',       'Andrés Cardona Ospina',    'andres.cardona@turismouq.co',  'S');
INSERT INTO usuario_sistema (id_usuario, id_rol, usuario_bd, nombre, correo, activo)
  VALUES ( 3, 2, 'TQ_ENC_FINCAS',   'Marta Giraldo Henao',      'marta.giraldo@turismouq.co',   'S');
INSERT INTO usuario_sistema (id_usuario, id_rol, usuario_bd, nombre, correo, activo)
  VALUES ( 4, 2, 'TQ_ENC_HOTELES',  'Jorge Valencia Arango',    'jorge.valencia@turismouq.co',  'S');
INSERT INTO usuario_sistema (id_usuario, id_rol, usuario_bd, nombre, correo, activo)
  VALUES ( 5, 2, 'TQ_ENC_GLAMPING', 'Natalia Osorio Marín',     'natalia.osorio@turismouq.co',  'S');
INSERT INTO usuario_sistema (id_usuario, id_rol, usuario_bd, nombre, correo, activo)
  VALUES ( 6, 2, 'TQ_ENC_HOSTALES', 'Felipe Castaño Duque',     'felipe.castano@turismouq.co',  'S');
INSERT INTO usuario_sistema (id_usuario, id_rol, usuario_bd, nombre, correo, activo)
  VALUES ( 7, 2, 'TQ_ENC_CABANAS',  'Paula Quintero Zapata',    'paula.quintero@turismouq.co',  'S');
INSERT INTO usuario_sistema (id_usuario, id_rol, usuario_bd, nombre, correo, activo)
  VALUES ( 8, 3, 'TQ_RECEPCION',    'Camilo Jaramillo Mejía',   'camilo.jaramillo@turismouq.co','S');
INSERT INTO usuario_sistema (id_usuario, id_rol, usuario_bd, nombre, correo, activo)
  VALUES ( 9, 4, 'TQ_GERENTE',      'Sofía Montoya Salazar',    'sofia.montoya@turismouq.co',   'S');
INSERT INTO usuario_sistema (id_usuario, id_rol, usuario_bd, nombre, correo, activo)
  VALUES (10, 5, 'TQ_AUDITOR',      'Ricardo Londoño Echeverri','ricardo.londono@turismouq.co', 'S');
COMMIT;

/* =====================================================================
  3. ALOJAMIENTO (60)
  define cuántos alojamientos de cada tipo hay en cada municipio. En Salento (12), Armenia (10),
  Filandia (8). Pijao, Córdoba y Génova solo 1. Armenia concentra  hoteles; Salento y Filandia, glampings y hostales.
   ===================================================================== */
   
DECLARE
  TYPE t_num IS TABLE OF PLS_INTEGER;
  TYPE t_txt IS TABLE OF VARCHAR2(60);

  v_dist t_num := t_num(
    -- F  H  G  Ho C
       1, 6, 0, 3, 0,   --  1 Armenia     (10)
       1, 0, 1, 0, 0,   --  2 Buenavista  ( 2)
       2, 1, 0, 1, 1,   --  3 Calarcá     ( 5)
       2, 0, 1, 1, 0,   --  4 Circasia    ( 4)
       1, 0, 0, 0, 0,   --  5 Córdoba     ( 1)
       2, 1, 2, 2, 1,   --  6 Filandia    ( 8)
       0, 0, 0, 0, 1,   --  7 Génova      ( 1)
       1, 2, 0, 0, 0,   --  8 La Tebaida  ( 3)
       3, 2, 1, 0, 1,   --  9 Montenegro  ( 7)
       1, 0, 0, 0, 0,   -- 10 Pijao       ( 1)
       2, 2, 1, 0, 1,   -- 11 Quimbaya    ( 6)
       3, 1, 3, 3, 2    -- 12 Salento     (12)
  );
  v_mun  t_txt := t_txt('Armenia','Buenavista','Calarcá','Circasia','Córdoba','Filandia',
                        'Génova','La Tebaida','Montenegro','Pijao','Quimbaya','Salento');
  v_pref t_txt := t_txt('Finca','Hotel','Glamping','Hostal','Cabañas');
  v_vereda t_txt := t_txt('La Española','El Caimo','Boquía','Palestina','La Bella',
                          'Cocora','Barcelona Alta','El Roble');
                          
  -- 64 nombres únicos (se usan los primeros 60, uno por alojamiento).
  
  v_nom t_txt := t_txt(
    'El Mirador','La Palma de Cera','Café y Niebla','Los Guaduales','Bosque de Niebla',
    'La Cosecha','Altos del Cocora','El Arriero','La Esperanza','Monte Verde',
    'El Barranquero','La Chapolera','Bahareque','El Yarumo','Las Heliconias',
    'El Recodo','Brisas del Quindío','La Fonda','El Colibrí','Villa Café',
    'La Montaña','El Paraíso','Tierra Alta','El Cafetal','La Ceiba',
    'Río Verde','El Edén','La Arboleda','Cielo Abierto','La Pradera',
    'El Retiro','Mirador del Valle','La Hacienda','El Portal','Santa Clara',
    'San Rafael','La Primavera','El Encanto','Los Alpes','Buenos Aires',
    'Piedra Azul','El Roble','Sol de Montaña','El Nogal','La Gaitana',
    'Las Acacias','El Tucán','La Herradura','Agua Clara','El Guamal',
    'Luna Llena','El Jardín','La Floresta','Puerto Espejo','El Balcón',
    'La Selva','Los Naranjos','El Rocío','Casa Grande','Valle Escondido',
    'El Ensueño','La Cascada','El Bambú','Guayacanes');

  v_id  PLS_INTEGER := 0;
  v_est PLS_INTEGER;
  v_dir VARCHAR2(150);
  v_tel VARCHAR2(20);

  FUNCTION rnd(p_a PLS_INTEGER, p_b PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN
    RETURN TRUNC(DBMS_RANDOM.VALUE(p_a, p_b + 1));   -- entero entre p_a y p_b
  END;
BEGIN
  FOR m IN 1 .. 12 LOOP
    FOR t IN 1 .. 5 LOOP
      FOR k IN 1 .. v_dist((m - 1) * 5 + t) LOOP
        v_id := v_id + 1;

        -- Estrellas autoasignadas según el tipo.
        v_est := CASE t
                   WHEN 1 THEN rnd(3, 5)                                    -- finca
                   WHEN 2 THEN CASE WHEN m = 1 THEN rnd(4, 5) ELSE rnd(3, 5) END  -- hotel
                   WHEN 3 THEN rnd(4, 5)                                    -- glamping
                   WHEN 4 THEN rnd(1, 3)                                    -- hostal
                   ELSE        rnd(2, 4)                                    -- cabañas
                 END;

        -- Hoteles y hostales en el casco urbano; el resto en zona rural.
        IF t IN (2, 4) THEN
          v_dir := 'Calle ' || rnd(1, 50) || ' # ' || rnd(1, 40) || '-' || rnd(2, 99) || ', ' || v_mun(m);
        ELSE
          v_dir := 'Km ' || rnd(1, 15) || ' vía ' || v_mun(m) || ', vereda ' || v_vereda(rnd(1, 8));
        END IF;

        -- Las funciones locales (rnd) no se pueden usar dentro de SQL:
        -- el teléfono se calcula antes en una variable.
        v_tel := '3' || rnd(100000000, 999999999);

        INSERT INTO alojamiento (id_alojamiento, id_municipio, id_tipo_alojamiento, id_encargado,
                                 nombre_comercial, direccion, estrellas, telefono, correo)
        VALUES (v_id, m, t, t + 2,
                v_pref(t) || ' ' || v_nom(v_id),
                v_dir,
                v_est,
                v_tel,
                'reservas@' || TRANSLATE(LOWER(v_nom(v_id)), 'áéíóúñü ', 'aeiounu') || '.com');
      END LOOP;
    END LOOP;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('3. Alojamientos: ' || v_id);
END;
/

/* =====================================================================
   4. HABITACION (~580, asimétrico)
   Registra las habitaciones por alojamiento según su tipo:  Hotel en Armenia: los 2 primeros 34-40 (hoteles grandes), el resto 15-28
   Hotel fuera de Armenia: 10-20 | Hostal: 6-14 | Cabañas: 4-10 | Glamping: 4-8 | Finca cafetera: 3-6
   Numeración: hoteles por piso (101, 102 ... 201), glampings DOMO-01, cabañas CAB-01, resto 01, 02 ...
   ===================================================================== */
   
DECLARE
  TYPE t_txt IS TABLE OF VARCHAR2(60);
  v_vista t_txt := t_txt('con vista a las montañas', 'con vista al cafetal', 'con balcón privado',
                         'con vista al jardín', 'con vista al valle', 'con baño privado');
  v_id      PLS_INTEGER := 0;
  v_n       PLS_INTEGER;
  v_hot_arm PLS_INTEGER := 0;
  v_tipo    VARCHAR2(10);
  v_cap     PLS_INTEGER;
  v_num     VARCHAR2(10);
  v_desc    VARCHAR2(300);
  v_u       NUMBER;

  FUNCTION rnd(p_a PLS_INTEGER, p_b PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN
    RETURN TRUNC(DBMS_RANDOM.VALUE(p_a, p_b + 1));
  END;
BEGIN
  FOR a IN (SELECT id_alojamiento, id_municipio, id_tipo_alojamiento
            FROM   alojamiento
            ORDER  BY id_alojamiento) LOOP

    -- Número de habitaciones según el tipo (asimetría pedida en 1.1).
    
    IF a.id_tipo_alojamiento = 2 THEN
      IF a.id_municipio = 1 THEN
        v_hot_arm := v_hot_arm + 1;
        v_n := CASE WHEN v_hot_arm <= 2 THEN rnd(34, 40) ELSE rnd(15, 28) END;
      ELSE
        v_n := rnd(10, 20);
      END IF;
    ELSIF a.id_tipo_alojamiento = 1 THEN v_n := rnd(3, 6);
    ELSIF a.id_tipo_alojamiento = 3 THEN v_n := rnd(4, 8);
    ELSIF a.id_tipo_alojamiento = 4 THEN v_n := rnd(6, 14);
    ELSE                                 v_n := rnd(4, 10);
    END IF;

    FOR i IN 1 .. v_n LOOP
      v_u := DBMS_RANDOM.VALUE;
      v_tipo := CASE a.id_tipo_alojamiento
                  WHEN 1 THEN CASE WHEN v_u < 0.25 THEN 'SENCILLA' WHEN v_u < 0.80 THEN 'DOBLE' ELSE 'SUITE' END
                  WHEN 2 THEN CASE WHEN v_u < 0.30 THEN 'SENCILLA' WHEN v_u < 0.85 THEN 'DOBLE' ELSE 'SUITE' END
                  WHEN 3 THEN CASE WHEN v_u < 0.70 THEN 'DOBLE' ELSE 'SUITE' END
                  WHEN 4 THEN CASE WHEN v_u < 0.45 THEN 'SENCILLA' ELSE 'DOBLE' END
                  ELSE 'CABANA'
                END;

      v_cap := CASE v_tipo
                 WHEN 'SENCILLA' THEN rnd(1, 2)
                 WHEN 'DOBLE'    THEN rnd(2, 3)
                 WHEN 'SUITE'    THEN rnd(2, 4)
                 ELSE                 rnd(4, 8)
               END;

      v_num := CASE a.id_tipo_alojamiento
                 WHEN 2 THEN TO_CHAR((TRUNC((i - 1) / 10) + 1) * 100 + MOD(i - 1, 10) + 1)
                 WHEN 3 THEN 'DOMO-' || LPAD(i, 2, '0')
                 WHEN 5 THEN 'CAB-'  || LPAD(i, 2, '0')
                 ELSE        LPAD(i, 2, '0')
               END;

      IF v_tipo = 'CABANA' THEN
        v_desc := 'Cabaña para ' || v_cap || ' personas ' || v_vista(rnd(1, 6));
      ELSE
        v_desc := 'Habitación ' || LOWER(v_tipo) || ' para ' || v_cap ||
                  CASE WHEN v_cap = 1 THEN ' persona ' ELSE ' personas ' END || v_vista(rnd(1, 6));
      END IF;

      v_id := v_id + 1;
      INSERT INTO habitacion (id_habitacion, id_alojamiento, numero, capacidad_max, tipo_habitacion, descripcion)
      VALUES (v_id, a.id_alojamiento, v_num, v_cap, v_tipo, v_desc);
    END LOOP;
  END LOOP;

  IF v_id < 400 THEN
    RAISE_APPLICATION_ERROR(-20002, 'Se generaron ' || v_id || ' habitaciones (< 400). Cambie la semilla.');
  END IF;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('4. Habitaciones: ' || v_id);
END;
/

/* =====================================================================
   5. SERVICIO (30)
   Se asigna a cada tipo de alojamiento un catálogo de 5 servicios típicos.
   Reparto de los 30 servicios:
     a) Un alojamiento de cada tipo recibe 2 servicios (10), para que haya servicios en todos los tipos.
     
     b) Los 20 restantes van a los alojamientos más populares, de 2 a 4 cada uno.
   ===================================================================== */
   
DECLARE
  TYPE t_txt  IS TABLE OF VARCHAR2(80);
  TYPE t_num  IS TABLE OF NUMBER;
  TYPE t_nidx IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

  -- Catálogo: 5 servicios por tipo, en el orden FINCA, HOTEL, GLAMPING, HOSTAL, CABAÑAS.
  
  v_snom t_txt := t_txt(
    'Tour del café',            'Desayuno campesino',   'Cabalgata',           'Avistamiento de aves', 'Caminata ecológica',
    'Desayuno buffet',          'Transporte aeropuerto','Spa y masajes',       'Tour Parque del Café', 'Cena gourmet',
    'Cena romántica',           'Jacuzzi privado',      'Fogata nocturna',     'Avistamiento de aves', 'Desayuno en el domo',
    'Alquiler de bicicletas',   'Tour Valle del Cocora','Desayuno continental','Lavandería',           'Clase de barismo',
    'Kit de asado',             'Tour Valle del Cocora','Leña para chimenea',  'Desayuno a la cabaña', 'Pesca deportiva');
  v_sdesc t_txt := t_txt(
    'Recorrido por el cultivo, beneficio y catación de café.', 'Desayuno típico con arepa, huevos y chocolate.',
    'Paseo a caballo de dos horas por la finca.',              'Salida guiada al amanecer con binoculares.',
    'Caminata guiada por senderos de la reserva.',
    'Desayuno buffet nacional e internacional.',               'Traslado desde o hacia el aeropuerto El Edén.',
    'Sesión de masaje relajante de 60 minutos.',                'Entrada y transporte al Parque Nacional del Café.',
    'Cena de tres tiempos con cocina de autor.',
    'Cena para dos con decoración especial.',                   'Uso privado del jacuzzi por dos horas.',
    'Fogata con malvaviscos y bebida caliente.',                'Recorrido guiado para observar aves endémicas.',
    'Desayuno servido en el domo.',
    'Alquiler de bicicleta por día.',                           'Transporte y guía al Valle del Cocora.',
    'Café, pan, fruta y huevos.',                               'Lavado y secado de ropa por bolsa.',
    'Taller de métodos de preparación de café.',
    'Carbón, parrilla y utensilios para asado.',                'Transporte y guía al Valle del Cocora.',
    'Carga de leña para la chimenea de la cabaña.',             'Desayuno entregado en la cabaña.',
    'Equipo y permiso para pesca en el lago.');
  v_sprec t_num := t_num(
     45000, 18000, 60000, 50000, 30000,
     32000, 65000,120000, 95000, 85000,
    150000, 90000, 35000, 55000, 28000,
     30000, 80000, 15000, 20000, 40000,
     50000, 85000, 25000, 22000, 45000);

  v_aloj t_nidx;      -- alojamientos ordenados por peso
  v_tipo t_nidx;
  v_asig t_nidx;      -- servicios asignados por id_alojamiento
  v_rest PLS_INTEGER := 30;
  v_k    PLS_INTEGER;
  v_ini  PLS_INTEGER;
  v_tot  PLS_INTEGER := 0;
  v_s    PLS_INTEGER;

  FUNCTION rnd(p_a PLS_INTEGER, p_b PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN
    RETURN TRUNC(DBMS_RANDOM.VALUE(p_a, p_b + 1));
  END;

  -- Se inserta p_k servicios distintos del catálogo del tipo p_t, empezando en una posición al azar.
  
  PROCEDURE asignar(p_aloj NUMBER, p_t NUMBER, p_k PLS_INTEGER) IS
  BEGIN
    v_ini := rnd(0, 4);
    FOR j IN 0 .. p_k - 1 LOOP
      v_s := (p_t - 1) * 5 + MOD(v_ini + j, 5) + 1;
      INSERT INTO servicio (id_alojamiento, nombre, descripcion, precio)
      VALUES (p_aloj, v_snom(v_s), v_sdesc(v_s),
              ROUND(v_sprec(v_s) * DBMS_RANDOM.VALUE(0.85, 1.25), -3));
      v_tot := v_tot + 1;
    END LOOP;
    v_asig(p_aloj) := p_k;
  END;
BEGIN
  WITH hab AS (
    SELECT id_alojamiento, COUNT(*) AS n
    FROM   habitacion
    GROUP  BY id_alojamiento
  )
  SELECT a.id_alojamiento, a.id_tipo_alojamiento
  BULK COLLECT INTO v_aloj, v_tipo
  FROM   alojamiento a
  JOIN   hab h ON h.id_alojamiento = a.id_alojamiento
  ORDER  BY POWER(h.n, 0.75)
          * CASE a.id_municipio WHEN 1 THEN 1.0 WHEN 2 THEN 0.7 WHEN 3 THEN 0.9 WHEN 4 THEN 0.8
                                WHEN 5 THEN 0.5 WHEN 6 THEN 1.5 WHEN 7 THEN 0.4 WHEN 8 THEN 0.9
                                WHEN 9 THEN 1.4 WHEN 10 THEN 0.5 WHEN 11 THEN 1.3 ELSE 1.8 END
          * CASE a.id_tipo_alojamiento WHEN 1 THEN 1.3 WHEN 2 THEN 0.8 WHEN 3 THEN 1.4
                                       WHEN 4 THEN 1.0 ELSE 1.1 END
          * (0.5 + ORA_HASH(a.id_alojamiento, 999, 48251) / 1000)       -- semilla 48251
          DESC;

  -- a) El alojamiento más popular de cada tipo recibe 2 servicios.
  
  FOR t IN 1 .. 5 LOOP
    FOR i IN 1 .. v_aloj.COUNT LOOP
      IF v_tipo(i) = t THEN
        asignar(v_aloj(i), t, 2);
        v_rest := v_rest - 2;
        EXIT;
      END IF;
    END LOOP;
  END LOOP;

  -- b) Los servicios restantes van a los más populares que aún no tienen.
  
  FOR i IN 1 .. v_aloj.COUNT LOOP
    EXIT WHEN v_rest = 0;
    IF NOT v_asig.EXISTS(v_aloj(i)) THEN
      v_k := LEAST(rnd(2, 4), v_rest);
      asignar(v_aloj(i), v_tipo(i), v_k);
      v_rest := v_rest - v_k;
    END IF;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('5. Servicios: ' || v_tot || ' en ' || v_asig.COUNT || ' alojamientos');
END;
/

/* =====================================================================
   6. TEMPORADA (~59)
   Definen el calendario continuo de las temporadas:
   * ALTA Semana Santa, mitad de año, fin de año (diciembre-enero) y los puentes festivos (viernes a domingo antes del lunes festivo).
   * Media:Donde van los dias entre temporada ALTA (marzo, junio, julio, agosto, diciembre) >
   * BAJA (resto del año).
   ===================================================================== */
DECLARE
  TYPE t_txt IS TABLE OF VARCHAR2(60);
  TYPE t_fec IS TABLE OF DATE;

  -- Temporadas altas en orden cronológico.
  
  a_nom t_txt := t_txt(
    'FIN DE AÑO 2023-2024',
    'SEMANA SANTA 2024',            'PUENTE DE LA ASCENSIÓN 2024',   'MITAD DE AÑO 2024',
    'PUENTE DE LA ASUNCIÓN 2024',   'PUENTE DÍA DE LA RAZA 2024',    'PUENTE DE TODOS LOS SANTOS 2024',
    'FIN DE AÑO 2024-2025',
    'PUENTE DE SAN JOSÉ 2025',      'SEMANA SANTA 2025',             'PUENTE DE LA ASCENSIÓN 2025',
    'MITAD DE AÑO 2025',            'PUENTE DE LA ASUNCIÓN 2025',    'PUENTE DÍA DE LA RAZA 2025',
    'PUENTE DE TODOS LOS SANTOS 2025', 'FIN DE AÑO 2025-2026',
    'PUENTE DE SAN JOSÉ 2026',      'SEMANA SANTA 2026',             'PUENTE DE LA ASCENSIÓN 2026',
    'MITAD DE AÑO 2026',            'PUENTE DE LA ASUNCIÓN 2026',    'PUENTE DÍA DE LA RAZA 2026',
    'PUENTE DE TODOS LOS SANTOS 2026', 'FIN DE AÑO 2026-2027');
  a_ini t_fec := t_fec(
    DATE '2023-12-15',
    DATE '2024-03-22', DATE '2024-05-10', DATE '2024-06-21',
    DATE '2024-08-16', DATE '2024-10-11', DATE '2024-11-01',
    DATE '2024-12-13',
    DATE '2025-03-21', DATE '2025-04-11', DATE '2025-05-30',
    DATE '2025-06-20', DATE '2025-08-15', DATE '2025-10-10',
    DATE '2025-10-31', DATE '2025-12-12',
    DATE '2026-03-20', DATE '2026-03-27', DATE '2026-05-15',
    DATE '2026-06-19', DATE '2026-08-14', DATE '2026-10-09',
    DATE '2026-10-30', DATE '2026-12-11');
  -- fecha_fin es la última noche de la temporada (inclusiva).
  a_fin t_fec := t_fec(
    DATE '2024-01-14',
    DATE '2024-03-31', DATE '2024-05-12', DATE '2024-07-14',
    DATE '2024-08-18', DATE '2024-10-13', DATE '2024-11-03',
    DATE '2025-01-12',
    DATE '2025-03-23', DATE '2025-04-20', DATE '2025-06-01',
    DATE '2025-07-13', DATE '2025-08-17', DATE '2025-10-12',
    DATE '2025-11-02', DATE '2026-01-11',
    DATE '2026-03-22', DATE '2026-04-05', DATE '2026-05-17',
    DATE '2026-07-12', DATE '2026-08-16', DATE '2026-10-11',
    DATE '2026-11-01', DATE '2027-01-10');

  c_desde CONSTANT DATE := DATE '2023-12-15';
  c_hasta CONSTANT DATE := DATE '2027-01-10';
  v_x     DATE;
  v_e     DATE;
  v_p     PLS_INTEGER := 1;     -- próxima temporada alta por insertar
  v_id    PLS_INTEGER := 0;
  v_clase VARCHAR2(5);

  -- Clase de un día que no es temporada alta, según su mes.
  
  FUNCTION clase(p_dia DATE) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE WHEN EXTRACT(MONTH FROM p_dia) IN (3, 6, 7, 8, 12) THEN 'MEDIA' ELSE 'BAJA' END;
  END;

  PROCEDURE ins(p_tipo NUMBER, p_nom VARCHAR2, p_ini DATE, p_fin DATE) IS
  BEGIN
    v_id := v_id + 1;
    INSERT INTO temporada (id_temporada, id_tipo_temporada, nombre, anio, fecha_inicio, fecha_fin)
    VALUES (v_id, p_tipo, p_nom, EXTRACT(YEAR FROM p_ini), p_ini, p_fin);
  END;
BEGIN
  v_x := c_desde;
  WHILE v_x <= c_hasta LOOP
    IF v_p <= a_ini.COUNT AND v_x = a_ini(v_p) THEN
      -- Temporada alta definida en la lista.
      ins(1, a_nom(v_p), a_ini(v_p), a_fin(v_p));
      v_x := a_fin(v_p) + 1;
      v_p := v_p + 1;
    ELSE
      -- Tramo entre temporadas altas: se extiende mientras no llegue la
      -- siguiente alta y no cambie la clase (MEDIA/BAJA) del mes.
      v_clase := clase(v_x);
      v_e := v_x;
      WHILE v_e + 1 <= c_hasta
        AND (v_p > a_ini.COUNT OR v_e + 1 < a_ini(v_p))
        AND clase(v_e + 1) = v_clase
      LOOP
        v_e := v_e + 1;
      END LOOP;
      ins(CASE v_clase WHEN 'MEDIA' THEN 2 ELSE 3 END,
          v_clase || ' ' || TO_CHAR(v_x, 'DD/MM/YYYY') || ' - ' || TO_CHAR(v_e, 'DD/MM/YYYY'),
          v_x, v_e);
      v_x := v_e + 1;
    END IF;
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('6. Temporadas: ' || v_id);
END;
/

/* =====================================================================
   7. TARIFA (habitaciones x temporadas)
   Calcula y registra el valor por noche para cada combinación de habitación y temporada.
   El precio se determina multiplicando el valor base de la habitación por el factor de cada temporada y el ajuste por inflación.
   
   valor_noche = base de la habitación x factor de temporada x inflación
   
     - Base: según tipo de alojamiento y estrellas, ajustada por tipo de
       habitación (sencilla 0.75, suite 1.6) y una variación de +/-10 %
       por habitación.
       
     - Factor de temporada PROPIO de cada alojamiento: MEDIA entre 1.10
       y 1.25; ALTA entre 0.05 y 0.60 por encima de su MEDIA. Así unos
       alojamientos suben mucho en alta y otros poco para competir por
       volumen 
       
     - Inflación anual: 2023 0.95 | 2024 1.00 | 2025 1.07 | 2026 1.13.
   ===================================================================== */
   
INSERT INTO tarifa (id_habitacion, id_temporada, valor_noche)
SELECT h.id_habitacion,
       t.id_temporada,
       ROUND(
           -- Base por tipo de alojamiento y estrellas
           CASE a.id_tipo_alojamiento
             WHEN 1 THEN 140000 + a.estrellas * 25000     -- finca cafetera
             WHEN 2 THEN  60000 + a.estrellas * 40000     -- hotel
             WHEN 3 THEN 200000 + a.estrellas * 50000     -- glamping
             WHEN 4 THEN  35000 + a.estrellas * 15000     -- hostal
             ELSE        150000 + a.estrellas * 30000     -- cabañas
           END
           -- Ajuste por tipo de habitación
         * CASE h.tipo_habitacion
             WHEN 'SENCILLA' THEN 0.75
             WHEN 'SUITE'    THEN 1.60
             WHEN 'CABANA'   THEN 1 + (h.capacidad_max - 4) * 0.10
             ELSE 1
           END
           -- Variación propia de cada habitación (0.90 a 1.10)
         * (0.90 + ORA_HASH(h.id_habitacion, 20, 48252) / 100)                -- semilla 48252
           -- Factor de temporada propio de cada alojamiento
         * CASE tt.nombre
             WHEN 'BAJA'  THEN 1
             WHEN 'MEDIA' THEN 1.10 + ORA_HASH(a.id_alojamiento, 15, 48253) / 100            -- semilla 48253
             ELSE              1.15 + ORA_HASH(a.id_alojamiento, 15, 48253) / 100
                                    + ORA_HASH(a.id_alojamiento, 55, 48254) / 100            -- semilla 48254
           END
           -- Inflación anual
         * CASE t.anio WHEN 2023 THEN 0.95 WHEN 2024 THEN 1.00 WHEN 2025 THEN 1.07 ELSE 1.13 END
       , -3) AS valor_noche
FROM   habitacion h
JOIN   alojamiento a     ON a.id_alojamiento     = h.id_alojamiento
CROSS  JOIN temporada t
JOIN   tipo_temporada tt ON tt.id_tipo_temporada = t.id_tipo_temporada;

COMMIT;

/* =====================================================================
   8. CLIENTE (3.000)
   Registra la información de los clientes del sistema, con distribución de nacionalidades, tipos de documento y diversas ciudades de origen.
   
   - 85 % colombianos con CC, 3 % residentes extranjeros con CE,
     2 % con PPT y 10 % turistas extranjeros con pasaporte (PA).
     
   - Ciudades de origen ponderadas: Bogotá, Medellín y Cali pesan más;
     los extranjeros vienen de 12 ciudades de otros países.
     
   - Documento y correo únicos por construcción (incluyen el número
     del cliente).
   ===================================================================== */
   
DECLARE
  TYPE t_txt IS TABLE OF VARCHAR2(40);
  TYPE t_num IS TABLE OF NUMBER;

  v_nombres t_txt := t_txt(
    'Juan','María','Carlos','Ana','Luis','Laura','Andrés','Camila','Jorge','Valentina',
    'Santiago','Daniela','Felipe','Natalia','Sebastián','Paula','Diego','Juliana','Alejandro','Sofía',
    'Mateo','Mariana','David','Isabella','Nicolás','Carolina','Miguel','Gabriela','Javier','Catalina',
    'Ricardo','Manuela','Óscar','Lucía','Esteban','Alejandra','Fernando','Sara','Julián','Verónica');
  v_apellidos t_txt := t_txt(
    'García','Rodríguez','Martínez','López','González','Hernández','Pérez','Sánchez','Ramírez','Torres',
    'Flórez','Rivera','Gómez','Díaz','Restrepo','Cardona','Osorio','Giraldo','Ospina','Valencia',
    'Arango','Muñoz','Rojas','Jaramillo','Castaño','Henao','Quintero','Marín','Zapata','Montoya',
    'Salazar','Duque','Mejía','Vargas','Castro','Ortiz','Moreno','Aristizábal','Londoño','Echeverri');
  v_cnac t_txt := t_txt('Bogotá','Medellín','Cali','Pereira','Armenia','Manizales','Barranquilla',
                        'Bucaramanga','Ibagué','Cartagena','Calarcá','Neiva','Villavicencio',
                        'Cúcuta','Tuluá','Santa Marta');
  v_pnac t_num := t_num(25, 15, 14, 9, 7, 6, 5, 4, 4, 3, 2, 2, 2, 2, 1, 1);   -- pesos
  v_cint t_txt := t_txt('Madrid','Ciudad de México','Miami','Nueva York','Quito','Lima',
                        'Buenos Aires','Santiago de Chile','Toronto','Berlín','París','Ciudad de Panamá');
  v_indi t_txt := t_txt('34','52','1','1','593','51','54','56','1','49','33','507');  -- indicativos
  v_dom  t_txt := t_txt('gmail.com','hotmail.com','outlook.com','yahoo.com','une.net.co','icloud.com');

  v_tdoc  VARCHAR2(3);
  v_ndoc  VARCHAR2(20);
  v_nom1  VARCHAR2(40);
  v_nom   VARCHAR2(80);
  v_ape1  VARCHAR2(40);
  v_ape   VARCHAR2(80);
  v_ciu   VARCHAR2(80);
  v_tel   VARCHAR2(20);
  v_correo VARCHAR2(120);
  v_freg  DATE;
  v_u     NUMBER;
  v_acum  NUMBER;
  v_k     PLS_INTEGER;
  v_total NUMBER := 0;

  FUNCTION rnd(p_a PLS_INTEGER, p_b PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN
    RETURN TRUNC(DBMS_RANDOM.VALUE(p_a, p_b + 1));
  END;

  FUNCTION sin_tildes(p VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN TRANSLATE(LOWER(p), 'áéíóúñü', 'aeiounu');
  END;
BEGIN
  FOR k IN 1 .. v_pnac.COUNT LOOP
    v_total := v_total + v_pnac(k);
  END LOOP;

  FOR i IN 1 .. 3000 LOOP
    v_nom1 := v_nombres(rnd(1, v_nombres.COUNT));
    v_nom  := v_nom1;
    IF DBMS_RANDOM.VALUE < 0.40 THEN
      v_nom := v_nom || ' ' || v_nombres(rnd(1, v_nombres.COUNT));   -- segundo nombre
    END IF;
    v_ape1 := v_apellidos(rnd(1, v_apellidos.COUNT));
    v_ape  := v_ape1 || ' ' || v_apellidos(rnd(1, v_apellidos.COUNT));

    v_u := DBMS_RANDOM.VALUE;
    IF v_u < 0.10 THEN
      -- Turista extranjero: pasaporte, ciudad y teléfono de otro país.
      v_k    := rnd(1, v_cint.COUNT);
      v_tdoc := 'PA';
      v_ndoc := CHR(65 + MOD(i, 26)) || CHR(65 + MOD(i * 7, 26)) || LPAD(i, 7, '0');
      v_ciu  := v_cint(v_k);
      v_tel  := '+' || v_indi(v_k) || ' ' || rnd(100000000, 999999999);
    ELSE
      -- Residente en Colombia: ciudad nacional ponderada.
      v_u := DBMS_RANDOM.VALUE(0, v_total);
      v_acum := 0;
      FOR k IN 1 .. v_pnac.COUNT LOOP
        v_acum := v_acum + v_pnac(k);
        IF v_u < v_acum OR k = v_pnac.COUNT THEN
          v_ciu := v_cnac(k);
          EXIT;
        END IF;
      END LOOP;
      v_tel := '3' || rnd(100000000, 999999999);
      v_u := DBMS_RANDOM.VALUE;
      IF v_u < 0.033 THEN
        v_tdoc := 'CE';  v_ndoc := TO_CHAR(100000 + i * 31);
      ELSIF v_u < 0.055 THEN
        v_tdoc := 'PPT'; v_ndoc := TO_CHAR(5000000 + i * 13);
      ELSE
        v_tdoc := 'CC';  v_ndoc := TO_CHAR(1000000000 + i * 7919);
      END IF;
    END IF;

    -- Las funciones locales (rnd, sin_tildes) no se pueden usar dentro de
    -- SQL: el correo y la fecha de registro se calculan antes en variables.
    v_correo := sin_tildes(v_nom1) || '.' || sin_tildes(v_ape1) || i || '@' || v_dom(rnd(1, v_dom.COUNT));
    v_freg   := DATE '2023-01-01' + rnd(0, 1368);   -- se ajusta en la sección 9

    INSERT INTO cliente (id_cliente, tipo_documento, num_documento, nombres, apellidos,
                         correo, telefono, ciudad_origen, fecha_registro)
    VALUES (i, v_tdoc, v_ndoc, v_nom, v_ape, v_correo, v_tel, v_ciu, v_freg);
  END LOOP;
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('8. Clientes: 3000');
END;
/

/* =====================================================================
   9. RESERVA (25.000) y RESERVA_HABITACION (~28.600)
   Por cada reserva asigna y distribuye las reservas de forma determinística en el rango temporal 2024-2026.
   Configura la estacionalidad, número de noches y ocupación por cliente/alojamiento, donde se destaca:
   
     1. Fecha de llegada: se escoge con pesos por día entre el
        01/01/2024 y el 24/12/2026. Peso = temporada (ALTA 3.2,
        MEDIA 1.6, BAJA 0.8) x fin de semana (viernes y sábado 1.5)
        x año (2024 0.8, 2025 1.0, 2026 1.15). 
        
     2. Noches: 1 a 7, con más peso en estadías cortas.
     
     3. Alojamiento: se escoge con el mismo peso: (tamaño x municipio x tipo x factor propio). Por eso Salento y
        Filandia tienen más reservas que Pijao o Génova, y dentro de un municipio hay alojamientos claramente más rentables (RANK).
        
     4. Habitaciones: 88 % una, 9 % dos, 3 % tres. Solo se usan habitaciones LIBRES en esas noches: un arreglo en
        memoria marca las noches ocupadas por reservas no canceladas
        
     5. Estado según la fecha de corte (30/09/2026).
     
     6. Cliente: unos clientes frecuentes concentran muchas reservas y otros tienen pocas o ninguna.
   ===================================================================== */
   
DECLARE
  c_ini    CONSTANT DATE        := DATE '2024-01-01';
  c_ult_in CONSTANT DATE        := DATE '2026-12-24';   -- última llegada posible
  c_corte  CONSTANT DATE        := DATE '2026-09-30';   -- "hoy" del negocio
  c_meta   CONSTANT PLS_INTEGER := 25000;

  TYPE t_num  IS TABLE OF NUMBER       INDEX BY PLS_INTEGER;
  TYPE t_fec  IS TABLE OF DATE         INDEX BY PLS_INTEGER;
  TYPE t_txt  IS TABLE OF VARCHAR2(12) INDEX BY PLS_INTEGER;
  TYPE t_bool IS TABLE OF BOOLEAN      INDEX BY PLS_INTEGER;

  -- Habitaciones (ordenadas por alojamiento)
  
  h_id   t_num;
  h_aloj t_num;
  h_cap  t_num;
  
  -- Alojamientos
  
  a_id    t_num;
  a_peso  t_num;
  a_cum   t_num;       -- peso acumulado
  a_first t_num;       -- posición de su primera habitación en h_*
  a_cnt   t_num;       -- número de habitaciones
  a_pos   t_num;       -- posición del alojamiento, indexado por id
  
  -- Días
  
  d_tipo t_txt;        -- tipo de temporada de cada día (índice 0..n-1)
  d_cum  t_num;        -- peso acumulado (índice 1..n)
  
  -- Ocupación: clave = posición_habitación * 1200 + desplazamiento_del_día
  
  ocupado t_bool;
  
  -- Filas a insertar
  
  r_id t_num; r_cli t_num; r_aloj t_num; r_fres t_fec; r_in t_fec; r_out t_fec; r_est t_txt;
  l_id t_num; l_res t_num; l_hab t_num; l_in t_fec; l_out t_fec; l_hue t_num;

  v_ndias    PLS_INTEGER;
  v_nal      PLS_INTEGER;
  v_ncli     PLS_INTEGER;
  v_res      PLS_INTEGER := 0;
  v_lin      PLS_INTEGER := 0;
  v_intentos PLS_INTEGER := 0;
  v_off      PLS_INTEGER;
  v_noches   PLS_INTEGER;
  v_ai       PLS_INTEGER;
  v_nhab     PLS_INTEGER;
  v_cnt      PLS_INTEGER;
  v_ri       PLS_INTEGER;
  v_loff     PLS_INTEGER;
  v_ln       PLS_INTEGER;
  v_cap      PLS_INTEGER;
  v_lead     PLS_INTEGER;
  v_dow      PLS_INTEGER;
  v_u        NUMBER;
  v_peso     NUMBER;
  v_dia      DATE;
  v_in       DATE;
  v_out      DATE;
  v_fres     DATE;
  v_est      VARCHAR2(12);
  v_rep      BOOLEAN;
  v_eleg     t_num;

  FUNCTION rnd(p_a PLS_INTEGER, p_b PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN
    RETURN TRUNC(DBMS_RANDOM.VALUE(p_a, p_b + 1));
  END;

  -- Búsqueda binaria sobre un arreglo de pesos acumulados:
  -- devuelve la primera posición cuyo acumulado es >= p_x.
  FUNCTION buscar(p_cum t_num, p_n PLS_INTEGER, p_x NUMBER) RETURN PLS_INTEGER IS
    lo  PLS_INTEGER := 1;
    hi  PLS_INTEGER := p_n;
    mid PLS_INTEGER;
  BEGIN
    WHILE lo < hi LOOP
      mid := TRUNC((lo + hi) / 2);
      IF p_cum(mid) < p_x THEN lo := mid + 1; ELSE hi := mid; END IF;
    END LOOP;
    RETURN lo;
  END;

  -- TRUE si la habitación (posición p_ri) está libre las p_n noches desde p_off.
  FUNCTION libre(p_ri PLS_INTEGER, p_off PLS_INTEGER, p_n PLS_INTEGER) RETURN BOOLEAN IS
  BEGIN
    FOR k IN 0 .. p_n - 1 LOOP
      IF ocupado.EXISTS(p_ri * 1200 + p_off + k) THEN
        RETURN FALSE;
      END IF;
    END LOOP;
    RETURN TRUE;
  END;
BEGIN
  SELECT COUNT(*) INTO v_ncli FROM cliente;

  -- 9.1 Habitaciones ordenadas por alojamiento
  
  SELECT id_habitacion, id_alojamiento, capacidad_max
  BULK COLLECT INTO h_id, h_aloj, h_cap
  FROM   habitacion
  ORDER  BY id_alojamiento, id_habitacion;

  -- 9.2 Peso de cada alojamiento
  
  WITH hab AS (
    SELECT id_alojamiento, COUNT(*) AS n
    FROM   habitacion
    GROUP  BY id_alojamiento
  )
  SELECT a.id_alojamiento,
         POWER(h.n, 0.75)
       * CASE a.id_municipio WHEN 1 THEN 1.0 WHEN 2 THEN 0.7 WHEN 3 THEN 0.9 WHEN 4 THEN 0.8
                             WHEN 5 THEN 0.5 WHEN 6 THEN 1.5 WHEN 7 THEN 0.4 WHEN 8 THEN 0.9
                             WHEN 9 THEN 1.4 WHEN 10 THEN 0.5 WHEN 11 THEN 1.3 ELSE 1.8 END
       * CASE a.id_tipo_alojamiento WHEN 1 THEN 1.3 WHEN 2 THEN 0.8 WHEN 3 THEN 1.4
                                    WHEN 4 THEN 1.0 ELSE 1.1 END
       * (0.5 + ORA_HASH(a.id_alojamiento, 999, 48251) / 1000)       -- semilla 48251
  BULK COLLECT INTO a_id, a_peso
  FROM   alojamiento a
  JOIN   hab h ON h.id_alojamiento = a.id_alojamiento
  ORDER  BY a.id_alojamiento;

  v_nal := a_id.COUNT;
  FOR i IN 1 .. v_nal LOOP
    a_pos(a_id(i)) := i;
    a_cnt(i) := 0;
    a_cum(i) := a_peso(i) + CASE WHEN i > 1 THEN a_cum(i - 1) ELSE 0 END;
  END LOOP;
  FOR r IN 1 .. h_id.COUNT LOOP
    v_ai := a_pos(h_aloj(r));
    IF a_cnt(v_ai) = 0 THEN a_first(v_ai) := r; END IF;
    a_cnt(v_ai) := a_cnt(v_ai) + 1;
  END LOOP;

  -- 9.3 Tipo de temporada y peso de cada día posible de llegada
  
  v_ndias := c_ult_in - c_ini + 1;
  FOR tp IN (SELECT t.fecha_inicio, t.fecha_fin, tt.nombre
             FROM   temporada t
             JOIN   tipo_temporada tt ON tt.id_tipo_temporada = t.id_tipo_temporada) LOOP
    FOR d IN GREATEST(tp.fecha_inicio - c_ini, 0) .. LEAST(tp.fecha_fin - c_ini, v_ndias - 1) LOOP
      d_tipo(d) := tp.nombre;
    END LOOP;
  END LOOP;

  FOR d IN 0 .. v_ndias - 1 LOOP
    v_dia  := c_ini + d;
    v_peso := CASE d_tipo(d) WHEN 'ALTA' THEN 3.2 WHEN 'MEDIA' THEN 1.6 ELSE 0.8 END;
    v_dow  := v_dia - TRUNC(v_dia, 'IW');          -- 0 = lunes ... 4 = viernes, 5 = sábado
    IF v_dow IN (4, 5) THEN v_peso := v_peso * 1.5; END IF;
    v_peso := v_peso * CASE EXTRACT(YEAR FROM v_dia) WHEN 2024 THEN 0.8 WHEN 2025 THEN 1.0 ELSE 1.15 END;
    d_cum(d + 1) := v_peso + CASE WHEN d > 0 THEN d_cum(d) ELSE 0 END;
  END LOOP;

  -- 9.4 Generación de reservas
  
  WHILE v_res < c_meta LOOP
    v_intentos := v_intentos + 1;
    IF v_intentos > c_meta * 4 THEN
      RAISE_APPLICATION_ERROR(-20010, 'Demasiados intentos sin habitaciones libres. Revise los datos.');
    END IF;

    -- Fecha de llegada y noches
    
    v_off := buscar(d_cum, v_ndias, DBMS_RANDOM.VALUE(0, d_cum(v_ndias))) - 1;
    v_u := DBMS_RANDOM.VALUE;
    v_noches := CASE WHEN v_u < 0.20 THEN 1 WHEN v_u < 0.50 THEN 2 WHEN v_u < 0.75 THEN 3
                     WHEN v_u < 0.87 THEN 4 WHEN v_u < 0.94 THEN 5 WHEN v_u < 0.98 THEN 6 ELSE 7 END;

    -- Alojamiento y número de habitaciones
    
    v_ai := buscar(a_cum, v_nal, DBMS_RANDOM.VALUE(0, a_cum(v_nal)));
    v_u := DBMS_RANDOM.VALUE;
    v_nhab := LEAST(CASE WHEN v_u < 0.88 THEN 1 WHEN v_u < 0.97 THEN 2 ELSE 3 END, a_cnt(v_ai));

    -- Se prueban hasta 8 habitaciones al azar del alojamiento
    
    v_eleg.DELETE;
    v_cnt := 0;
    FOR t IN 1 .. 8 LOOP
      v_ri := a_first(v_ai) + TRUNC(DBMS_RANDOM.VALUE(0, a_cnt(v_ai)));
      v_rep := FALSE;
      FOR j IN 1 .. v_cnt LOOP
        IF v_eleg(j) = v_ri THEN v_rep := TRUE; END IF;
      END LOOP;
      IF NOT v_rep AND libre(v_ri, v_off, v_noches) THEN
        v_cnt := v_cnt + 1;
        v_eleg(v_cnt) := v_ri;
      END IF;
      EXIT WHEN v_cnt = v_nhab;
    END LOOP;
    CONTINUE WHEN v_cnt = 0;      -- sin disponibilidad: se intenta otra combinación

    v_in  := c_ini + v_off;
    v_out := v_in + v_noches;

    -- Estado según la fecha de corte
    
    v_u := DBMS_RANDOM.VALUE;
    IF v_out <= c_corte THEN
      v_est := CASE WHEN v_u < 0.13 THEN 'CANCELADA' ELSE 'COMPLETADA' END;
    ELSIF v_in > c_corte THEN
      v_est := CASE WHEN v_u < 0.10 THEN 'CANCELADA' WHEN v_u < 0.40 THEN 'PENDIENTE' ELSE 'CONFIRMADA' END;
    ELSE
      v_est := 'CONFIRMADA';      -- huésped alojado el día del corte
    END IF;

    -- Fecha en que se hizo la reserva: de 0 a 75 días antes (más peso cerca
    -- de la llegada), nunca después del corte. Se le agrega una hora del día.
    v_lead := TRUNC(POWER(DBMS_RANDOM.VALUE, 2) * 75);
    v_fres := v_in - v_lead;
    IF v_fres > c_corte THEN v_fres := c_corte; END IF;
    v_fres := v_fres + DBMS_RANDOM.VALUE(0.30, 0.95);

    v_res := v_res + 1;
    r_id(v_res)   := v_res;
    r_cli(v_res)  := GREATEST(1, CEIL(v_ncli * POWER(DBMS_RANDOM.VALUE, 1.6)));  -- clientes frecuentes
    r_aloj(v_res) := a_id(v_ai);
    r_fres(v_res) := v_fres;
    r_in(v_res)   := v_in;
    r_out(v_res)  := v_out;
    r_est(v_res)  := v_est;

    -- Líneas de la reserva
    
    FOR j IN 1 .. v_cnt LOOP
      v_ri   := v_eleg(j);
      v_loff := v_off;
      v_ln   := v_noches;
      -- 15 % de las líneas adicionales llegan un día después.
      IF j > 1 AND v_noches >= 2 AND DBMS_RANDOM.VALUE < 0.15 THEN
        v_loff := v_off + 1;
        v_ln   := v_noches - 1;
      END IF;

      v_cap := h_cap(v_ri);
      v_lin := v_lin + 1;
      l_id(v_lin)  := v_lin;
      l_res(v_lin) := v_res;
      l_hab(v_lin) := h_id(v_ri);
      l_in(v_lin)  := c_ini + v_loff;
      l_out(v_lin) := c_ini + v_loff + v_ln;
      l_hue(v_lin) := CASE WHEN v_cap >= 2 AND DBMS_RANDOM.VALUE < 0.55 THEN 2 ELSE rnd(1, v_cap) 
      END;

      -- Las canceladas no ocupan la habitación.
      
      IF v_est <> 'CANCELADA' THEN
        FOR k IN 0 .. v_ln - 1 LOOP
          ocupado(v_ri * 1200 + v_loff + k) := TRUE;
        END LOOP;
      END IF;
    END LOOP;
  END LOOP;

  -- 9.5 Inserción masiva
  
  FORALL i IN 1 .. v_res
    INSERT INTO reserva (id_reserva, id_cliente, id_alojamiento, fecha_reserva,
                         fecha_checkin, fecha_checkout, estado)
    VALUES (r_id(i), r_cli(i), r_aloj(i), r_fres(i), r_in(i), r_out(i), r_est(i));

  FORALL i IN 1 .. v_lin
    INSERT INTO reserva_habitacion (id_reserva_hab, id_reserva, id_habitacion,
                                    fecha_checkin, fecha_checkout, num_huespedes)
    VALUES (l_id(i), l_res(i), l_hab(i), l_in(i), l_out(i), l_hue(i));

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('9. Reservas: ' || v_res || ' | líneas: ' || v_lin ||
                       ' | intentos: ' || v_intentos);
END;
/

-- Coherencia: la fecha de registro de un cliente no puede ser posterior a su primera reserva.

UPDATE cliente c
SET    fecha_registro = (SELECT LEAST(c.fecha_registro, MIN(TRUNC(r.fecha_reserva)))
                         FROM   reserva r
                         WHERE  r.id_cliente = c.id_cliente)
WHERE  EXISTS (SELECT 1 FROM reserva r WHERE r.id_cliente = c.id_cliente);
COMMIT;

/* =====================================================================
   10. RESERVA_NOCHE (~80.000)
   Genera el desglose de tarifas por cada noche reservada.
   Cada noche toma la tarifa correspondiente a la habitación y temporada de esa fecha, registrando el precio congelado al momento de la reserva.
   Aqui se aplica la decisión de diseño 2 que tiene por lógica:
   
     - El generador de filas (CONNECT BY LEVEL) produce los números
       0..30; cada línea se cruza con tantos números como noches tiene.
       
     - Cada noche se une con la temporada cuyo rango la contiene y con
       la tarifa de esa habitación en esa temporada.
       
     - Una estadía que cruza de temporada media a alta queda con noches de tarifas distinta
   ===================================================================== */
   
INSERT INTO reserva_noche (id_reserva_hab, fecha_noche, id_tarifa, valor_noche)
SELECT rh.id_reserva_hab,
       rh.fecha_checkin + g.n,
       ta.id_tarifa,
       ta.valor_noche
FROM   reserva_habitacion rh
JOIN   (SELECT LEVEL - 1 AS n FROM dual CONNECT BY LEVEL <= 31) g
       ON g.n < rh.fecha_checkout - rh.fecha_checkin
JOIN   temporada t
       ON rh.fecha_checkin + g.n BETWEEN t.fecha_inicio AND t.fecha_fin
JOIN   tarifa ta
       ON ta.id_habitacion = rh.id_habitacion
      AND ta.id_temporada  = t.id_temporada;

COMMIT;

/* =====================================================================
   11. RESERVA_SERVICIO (>= 40.000)
   Asigna servicios adicionales a reservas activas, restringiéndolos al catálogo del mismo alojamiento.
   Registra la cantidad de servicios y congela el precio unitario aplicando un ajuste de tarifa según el año.
   
   Combinaciones posibles:
   
   * Cada reserva no cancelada x cada servicio de SU alojamiento x cada día de la estadía, desde la llegada
     hasta el día de salida inclusive (el desayuno del último día cuenta).
   
   * Cada combinación se incluye con una probabilidad calculada para llegar a la meta, ajustada por popularidad del servicio. 
     Si la primera pasada no alcanza 40.000, se hacen pasadas adicionales sobre las combinaciones que aún no existen.
   
   - cantidad: entre 1 y el número de huéspedes de la reserva (máx. 6).
   
   - precio_unitario: precio vigente con descuento por año (2024 88 %,
     2025 94 %), para que se vea que el precio quedó congelado.
   ===================================================================== */
   
DECLARE
  c_meta CONSTANT PLS_INTEGER := 40000;
  v_cap  NUMBER;
  v_ins  NUMBER;
  v_p    NUMBER;
  v_iter PLS_INTEGER := 0;
BEGIN
  SELECT COUNT(*) INTO v_cap
  FROM   reserva r
  JOIN   servicio s ON s.id_alojamiento = r.id_alojamiento
  JOIN   (SELECT LEVEL - 1 AS n FROM dual CONNECT BY LEVEL <= 31) g
         ON g.n <= r.fecha_checkout - r.fecha_checkin
  WHERE  r.estado <> 'CANCELADA';

  IF v_cap < c_meta THEN
    RAISE_APPLICATION_ERROR(-20020, 'Solo hay ' || v_cap || ' combinaciones posibles (< 40.000). Cambie la semilla.');
  END IF;

  -- Primera pasada
  v_p := 41000 / v_cap;
  INSERT INTO reserva_servicio (id_reserva, id_servicio, fecha_servicio, cantidad, precio_unitario)
  SELECT r.id_reserva,
         s.id_servicio,
         r.fecha_checkin + g.n,
         1 + TRUNC(DBMS_RANDOM.VALUE(0, LEAST(h.huespedes, 6))),
         ROUND(s.precio * CASE EXTRACT(YEAR FROM r.fecha_checkin + g.n)
                            WHEN 2024 THEN 0.88 WHEN 2025 THEN 0.94 ELSE 1 END, -2)
  FROM   reserva r
  JOIN   servicio s ON s.id_alojamiento = r.id_alojamiento
  JOIN   (SELECT LEVEL - 1 AS n FROM dual CONNECT BY LEVEL <= 31) g
         ON g.n <= r.fecha_checkout - r.fecha_checkin
  JOIN   (SELECT id_reserva, SUM(num_huespedes) AS huespedes
          FROM   reserva_habitacion
          GROUP  BY id_reserva) h ON h.id_reserva = r.id_reserva
  WHERE  r.estado <> 'CANCELADA'
  -- Sorteo por combinación. Se usa ORA_HASH sobre la combinación completa
  -- (reserva-servicio-día-pasada) y no DBMS_RANDOM.VALUE en el WHERE: como
  -- DBMS_RANDOM no depende de ninguna columna, el optimizador puede evaluarlo
  -- una sola vez para toda la consulta y entonces entran TODAS las
  -- combinaciones o ninguna. El hash cambia con cada fila, así que el
  -- sorteo es realmente por combinación (y además reproducible).
  AND    ORA_HASH(r.id_reserva || '-' || s.id_servicio || '-' || g.n || '-' || v_iter, 9999, 48258) / 10000
           < v_p * (0.6 + ORA_HASH(s.id_servicio, 80, 48257) / 100);   -- semillas 48258 y 48257
  v_ins := SQL%ROWCOUNT;

  -- Pasadas de ajuste hasta llegar a la meta
  
  WHILE v_ins < c_meta AND v_iter < 20 LOOP
    v_iter := v_iter + 1;
    v_p := (c_meta - v_ins + 300) / GREATEST(v_cap - v_ins, 1);
    INSERT INTO reserva_servicio (id_reserva, id_servicio, fecha_servicio, cantidad, precio_unitario)
    SELECT r.id_reserva,
           s.id_servicio,
           r.fecha_checkin + g.n,
           1 + TRUNC(DBMS_RANDOM.VALUE(0, LEAST(h.huespedes, 6))),
           ROUND(s.precio * CASE EXTRACT(YEAR FROM r.fecha_checkin + g.n)
                              WHEN 2024 THEN 0.88 WHEN 2025 THEN 0.94 ELSE 1 END, -2)
    FROM   reserva r
    JOIN   servicio s ON s.id_alojamiento = r.id_alojamiento
    JOIN   (SELECT LEVEL - 1 AS n FROM dual CONNECT BY LEVEL <= 31) g
           ON g.n <= r.fecha_checkout - r.fecha_checkin
    JOIN   (SELECT id_reserva, SUM(num_huespedes) AS huespedes
            FROM   reserva_habitacion
            GROUP  BY id_reserva) h ON h.id_reserva = r.id_reserva
    WHERE  r.estado <> 'CANCELADA'
    AND    NOT EXISTS (SELECT 1
                       FROM   reserva_servicio x
                       WHERE  x.id_reserva     = r.id_reserva
                       AND    x.id_servicio    = s.id_servicio
                       AND    x.fecha_servicio = r.fecha_checkin + g.n)
    AND    ORA_HASH(r.id_reserva || '-' || s.id_servicio || '-' || g.n || '-' || v_iter, 9999, 48258) / 10000
             < v_p;                                                       -- semilla 48258
    v_ins := v_ins + SQL%ROWCOUNT;
  END LOOP;

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('11. Líneas de servicio: ' || v_ins || ' (capacidad ' || v_cap || ')');
END;
/

/* =====================================================================
   12. PAGO (~32.000) y CANCELACION (~3.000)
   
   Calcula el total de la reserva (noches más servicios) y genera los pagos según su estado (completados, anticipos o intentos).
   En reservas canceladas, aplica la regla de reembolso: 80% de devolución si se cancela con más de 5 días de anticipación, y 0% si se realiza en 5 días o menos.
   El total de cada reserva = suma de sus noches + suma de sus servicios.
   
   Comportamiento por estado:
   
     COMPLETADA : 55 % pago único (a veces precedido de un intento
                  FALLIDO); 45 % anticipo (30-50 %) + saldo al llegar.
                  
     CONFIRMADA : en curso -> anticipo + saldo pagado o pendiente
     
                  futura   -> pago total, solo anticipo, o anticipo +
                              saldo PENDIENTE.
                              
     PENDIENTE  : sin pagos, un pago PENDIENTE o un intento FALLIDO.
     
     CANCELADA  : 70 % alcanzó a pagar anticipo. con más de 5 días de anticipación se reembolsa el
                  80 % y el pago queda REEMBOLSADO; con 5 días o menos no hay reembolso y el pago sigue EXITOSO.
   ===================================================================== */
   
DECLARE
  c_corte CONSTANT DATE := DATE '2026-09-30';

  CURSOR c_res IS
    SELECT r.id_reserva, r.estado, r.fecha_reserva, r.fecha_checkin, r.fecha_checkout,
           n.v_noches + NVL(s.v_serv, 0) AS total
    FROM   reserva r
    JOIN   (SELECT rh.id_reserva, SUM(rn.valor_noche) AS v_noches
            FROM   reserva_habitacion rh
            JOIN   reserva_noche rn ON rn.id_reserva_hab = rh.id_reserva_hab
            GROUP  BY rh.id_reserva) n ON n.id_reserva = r.id_reserva
    LEFT JOIN (SELECT id_reserva, SUM(cantidad * precio_unitario) AS v_serv
               FROM   reserva_servicio
               GROUP  BY id_reserva) s ON s.id_reserva = r.id_reserva
    ORDER  BY r.id_reserva;

  TYPE t_res IS TABLE OF c_res%ROWTYPE;
  TYPE t_num IS TABLE OF NUMBER        INDEX BY PLS_INTEGER;
  TYPE t_fec IS TABLE OF DATE          INDEX BY PLS_INTEGER;
  TYPE t_txt IS TABLE OF VARCHAR2(300) INDEX BY PLS_INTEGER;
  TYPE t_lst IS TABLE OF VARCHAR2(300);

  v_res t_res;
  -- Pagos
  p_res t_num; p_fec t_fec; p_mon t_num; p_met t_txt; p_est t_txt;
  v_np  PLS_INTEGER := 0;
  -- Cancelaciones
  k_res t_num; k_fec t_fec; k_dia t_num; k_pct t_num; k_mon t_num; k_mot t_txt;
  v_nk  PLS_INTEGER := 0;

  v_motivos t_lst := t_lst('Cambio de planes de viaje', 'Problemas de salud', 'Encontró otra opción de alojamiento',
                           'Motivos laborales', 'Mal clima pronosticado', NULL);

  v_total    NUMBER;
  v_anticipo NUMBER;
  v_u        NUMBER;
  v_span     NUMBER;
  v_fcan     DATE;
  v_dias     NUMBER;
  v_pagado   NUMBER;
  v_pct      NUMBER;
  v_monto    NUMBER;
  v_estpago  VARCHAR2(12);

  FUNCTION rnd(p_a PLS_INTEGER, p_b PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN
    RETURN TRUNC(DBMS_RANDOM.VALUE(p_a, p_b + 1));
  END;

  -- Método típico de un anticipo (pago en línea).
  
  FUNCTION met_anticipo RETURN VARCHAR2 IS
    u NUMBER := DBMS_RANDOM.VALUE;
  BEGIN
    RETURN CASE WHEN u < 0.35 THEN 'PSE' WHEN u < 0.70 THEN 'TARJETA_CREDITO'
                WHEN u < 0.90 THEN 'TRANSFERENCIA' ELSE 'TARJETA_DEBITO' END;
  END;

  -- Método típico del saldo pagado al llegar.
  
  FUNCTION met_saldo RETURN VARCHAR2 IS
    u NUMBER := DBMS_RANDOM.VALUE;
  BEGIN
    RETURN CASE WHEN u < 0.30 THEN 'EFECTIVO' WHEN u < 0.65 THEN 'TARJETA_CREDITO'
                WHEN u < 0.90 THEN 'TARJETA_DEBITO' ELSE 'TRANSFERENCIA' END;
  END;

  PROCEDURE add_pago(p_r NUMBER, p_f DATE, p_m NUMBER, p_metodo VARCHAR2, p_e VARCHAR2) IS
  BEGIN
    v_np := v_np + 1;
    p_res(v_np) := p_r; p_fec(v_np) := p_f; p_mon(v_np) := p_m;
    p_met(v_np) := p_metodo; p_est(v_np) := p_e;
  END;
BEGIN
  OPEN c_res;
  FETCH c_res BULK COLLECT INTO v_res;
  CLOSE c_res;

  FOR i IN 1 .. v_res.COUNT LOOP
    v_total    := v_res(i).total;
    v_anticipo := ROUND(v_total * DBMS_RANDOM.VALUE(0.30, 0.50), -3);
    IF v_anticipo <= 0 OR v_anticipo >= v_total THEN
      v_anticipo := ROUND(v_total / 2);
    END IF;
    v_u := DBMS_RANDOM.VALUE;

    IF v_res(i).estado = 'COMPLETADA' THEN
      IF v_u < 0.55 THEN
        IF DBMS_RANDOM.VALUE < 0.06 THEN
          add_pago(v_res(i).id_reserva, v_res(i).fecha_reserva, v_total, 'TARJETA_CREDITO', 'FALLIDO');
        END IF;
        add_pago(v_res(i).id_reserva, v_res(i).fecha_reserva + 5 / 1440, v_total, met_anticipo, 'EXITOSO');
      ELSE
        add_pago(v_res(i).id_reserva, v_res(i).fecha_reserva, v_anticipo, met_anticipo, 'EXITOSO');
        add_pago(v_res(i).id_reserva, v_res(i).fecha_checkin + DBMS_RANDOM.VALUE(0.55, 0.85),
             v_total - v_anticipo, met_saldo, 'EXITOSO');
      END IF;

    ELSIF v_res(i).estado = 'CONFIRMADA' THEN
      IF v_res(i).fecha_checkin <= c_corte THEN
        -- Huésped alojado: ya pagó el anticipo; el saldo puede estar pago o pendiente.
        add_pago(v_res(i).id_reserva, v_res(i).fecha_reserva, v_anticipo, met_anticipo, 'EXITOSO');
        add_pago(v_res(i).id_reserva, v_res(i).fecha_checkin + DBMS_RANDOM.VALUE(0.55, 0.85),
             v_total - v_anticipo, met_saldo,
             CASE WHEN v_u < 0.5 THEN 'EXITOSO' ELSE 'PENDIENTE' END);
      ELSIF v_u < 0.30 THEN
        add_pago(v_res(i).id_reserva, v_res(i).fecha_reserva, v_total, met_anticipo, 'EXITOSO');
      ELSIF v_u < 0.80 THEN
        add_pago(v_res(i).id_reserva, v_res(i).fecha_reserva, v_anticipo, met_anticipo, 'EXITOSO');
      ELSE
        add_pago(v_res(i).id_reserva, v_res(i).fecha_reserva, v_anticipo, met_anticipo, 'EXITOSO');
        add_pago(v_res(i).id_reserva, LEAST(c_corte, TRUNC(v_res(i).fecha_reserva) + rnd(1, 10)) + 0.5,
             v_total - v_anticipo, 'PSE', 'PENDIENTE');
      END IF;

    ELSIF v_res(i).estado = 'PENDIENTE' THEN
      IF v_u < 0.45 THEN
        NULL;                                                     -- aún sin pagos
      ELSIF v_u < 0.80 THEN
        add_pago(v_res(i).id_reserva, v_res(i).fecha_reserva, v_anticipo, 'PSE', 'PENDIENTE');
      ELSE
        add_pago(v_res(i).id_reserva, v_res(i).fecha_reserva, v_anticipo, 'TARJETA_CREDITO', 'FALLIDO');
      END IF;

    ELSE  -- CANCELADA
      -- Fecha de cancelación entre la reserva y la llegada (sin pasar el corte).
      v_span := LEAST(v_res(i).fecha_checkin, c_corte) - TRUNC(v_res(i).fecha_reserva);
      v_fcan := TRUNC(v_res(i).fecha_reserva) + TRUNC(DBMS_RANDOM.VALUE(0, v_span + 1));
      v_fcan := GREATEST(v_res(i).fecha_reserva, v_fcan + DBMS_RANDOM.VALUE(0.30, 0.90));
      v_dias := v_res(i).fecha_checkin - TRUNC(v_fcan);

      v_pagado := CASE WHEN v_u < 0.70 THEN v_anticipo ELSE 0 END;

      IF v_dias > 5 THEN            -- RN1: reembolso del 80 %
        v_pct := 80;  v_monto := ROUND(v_pagado * 0.80, -2);  v_estpago := 'REEMBOLSADO';
      ELSE                          -- RN1: sin reembolso
        v_pct := 0;   v_monto := 0;                          v_estpago := 'EXITOSO';
      END IF;

      IF v_pagado > 0 THEN
        add_pago(v_res(i).id_reserva, v_res(i).fecha_reserva, v_pagado, met_anticipo, v_estpago);
      END IF;

      v_nk := v_nk + 1;
      k_res(v_nk) := v_res(i).id_reserva;
      k_fec(v_nk) := v_fcan;
      k_dia(v_nk) := v_dias;
      k_pct(v_nk) := v_pct;
      k_mon(v_nk) := v_monto;
      k_mot(v_nk) := v_motivos(rnd(1, v_motivos.COUNT));
    END IF;
  END LOOP;

  FORALL i IN 1 .. v_np
    INSERT INTO pago (id_reserva, fecha_pago, monto, metodo, estado)
    VALUES (p_res(i), p_fec(i), p_mon(i), p_met(i), p_est(i));

  FORALL i IN 1 .. v_nk
    INSERT INTO cancelacion (id_reserva, fecha_cancelacion, dias_anticipacion,
                             porcentaje_reembolso, monto_reembolso, motivo)
    VALUES (k_res(i), k_fec(i), k_dia(i), k_pct(i), k_mon(i), k_mot(i));

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('12. Pagos: ' || v_np || ' | cancelaciones: ' || v_nk);
END;
/


/* =====================================================================
   13. RESENA (>= 40 % de las reservas completadas)
   Genera opiniones y calificaciones para al menos el 40% de las reservas completadas.
   Ajusta el promedio de estrellas según la calidad del alojamiento y permite comentarios opcionales donde:
   
   - Cada alojamiento tiene su propia probabilidad de recibir reseñas
     (35 % a 65 %) y su propia "calidad" (2.6 a 4.8 estrellas), así
     el promedio de calificación varía de verdad entre alojamientos.
     
   - Calificación = calidad + ruido normal, redondeada entre 1 y 5.
   
   - 30 % de las reseñas no tiene comentario (es opcional).
   
   - Si la primera pasada no llega al 42 %, se completan con un
     muestreo exacto sobre las reservas que quedaron sin reseña.
   ===================================================================== */
   
DECLARE
  c_corte CONSTANT DATE := DATE '2026-09-30';

  TYPE t_num IS TABLE OF NUMBER        INDEX BY PLS_INTEGER;
  TYPE t_fec IS TABLE OF DATE          INDEX BY PLS_INTEGER;
  TYPE t_txt IS TABLE OF VARCHAR2(400) INDEX BY PLS_INTEGER;
  TYPE t_lst IS TABLE OF VARCHAR2(400);

  c_id   t_num; c_out t_fec; c_prob t_num; c_cal t_num;
  e_res  t_num; e_cal t_num; e_com t_txt; e_fec t_fec;
  v_pend t_num;
  v_ne   PLS_INTEGER := 0;
  v_np   PLS_INTEGER := 0;
  v_meta PLS_INTEGER;

  v_malos t_lst := t_lst(
    'La habitación no correspondía a las fotos.', 'Mucho ruido en la noche y mala atención.',
    'El aseo dejó mucho que desear.', 'No volvería, la relación precio-calidad es mala.',
    'Hubo problemas con el agua caliente todos los días.');
  v_regulares t_lst := t_lst(
    'Buena ubicación, pero el servicio puede mejorar.', 'Cumplió lo básico, nada especial.',
    'El desayuno estuvo bien, las camas regulares.', 'Agradable, aunque un poco caro para lo que ofrece.',
    'La vista es bonita, pero faltó mantenimiento.');
  v_buenos t_lst := t_lst(
    'Excelente atención y una vista espectacular.', 'El café de la finca es delicioso, volveremos.',
    'Muy limpio, cómodo y el personal muy amable.', 'Ideal para descansar en familia.',
    'La mejor experiencia de nuestro viaje por el Quindío.', 'Todo perfecto, superó nuestras expectativas.');

  PROCEDURE agregar(i PLS_INTEGER) IS
    v_c NUMBER;
  BEGIN
    v_c := LEAST(5, GREATEST(1, ROUND(c_cal(i) + DBMS_RANDOM.NORMAL * 0.9)));
    v_ne := v_ne + 1;
    e_res(v_ne) := c_id(i);
    e_cal(v_ne) := v_c;
    e_fec(v_ne) := LEAST(c_out(i) + TRUNC(DBMS_RANDOM.VALUE(0, 21)), c_corte);
    IF DBMS_RANDOM.VALUE < 0.30 THEN
      e_com(v_ne) := NULL;
    ELSIF v_c <= 2 THEN
      e_com(v_ne) := v_malos(TRUNC(DBMS_RANDOM.VALUE(1, v_malos.COUNT + 1)));
    ELSIF v_c = 3 THEN
      e_com(v_ne) := v_regulares(TRUNC(DBMS_RANDOM.VALUE(1, v_regulares.COUNT + 1)));
    ELSE
      e_com(v_ne) := v_buenos(TRUNC(DBMS_RANDOM.VALUE(1, v_buenos.COUNT + 1)));
    END IF;
  END;
BEGIN
  SELECT id_reserva,
         fecha_checkout,
         0.35 + ORA_HASH(id_alojamiento, 30, 48255) / 100,      -- probabilidad de reseñar (semilla 48255)
         2.6  + ORA_HASH(id_alojamiento, 22, 48256) / 10        -- calidad del alojamiento (semilla 48256)
  BULK COLLECT INTO c_id, c_out, c_prob, c_cal
  FROM   reserva
  WHERE  estado = 'COMPLETADA'
  ORDER  BY id_reserva;

  -- Primera pasada: probabilidad propia de cada alojamiento.
  
  FOR i IN 1 .. c_id.COUNT LOOP
    IF DBMS_RANDOM.VALUE < c_prob(i) THEN
      agregar(i);
    ELSE
      v_np := v_np + 1;
      v_pend(v_np) := i;
    END IF;
  END LOOP;

  -- Ajuste: muestreo exacto hasta llegar al 42 % de las completadas.
  
  v_meta := CEIL(0.42 * c_id.COUNT);
  IF v_ne < v_meta THEN
    FOR j IN 1 .. v_np LOOP
      EXIT WHEN v_ne >= v_meta;
      IF DBMS_RANDOM.VALUE < (v_meta - v_ne) / (v_np - j + 1) THEN
        agregar(v_pend(j));
      END IF;
    END LOOP;
  END IF;

  FORALL i IN 1 .. v_ne
    INSERT INTO resena (id_reserva, calificacion, comentario, fecha_resena)
    VALUES (e_res(i), e_cal(i), e_com(i), e_fec(i));

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('13. Reseñas: ' || v_ne || ' de ' || c_id.COUNT || ' completadas (' ||
                       ROUND(100 * v_ne / GREATEST(c_id.COUNT, 1), 1) || ' %)');
END;
/

/* =====================================================================
   14. SINCRONIZACIÓN DE IDENTITY
   Se ajustan los contadores autoincrementables de las tablas para sincronizarlos con los IDs insertados previamente y evitar duplicados en futuros INSERT.
   ===================================================================== */
ALTER TABLE municipio          MODIFY (id_municipio        GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH LIMIT VALUE));
ALTER TABLE tipo_alojamiento   MODIFY (id_tipo_alojamiento GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH LIMIT VALUE));
ALTER TABLE rol                MODIFY (id_rol              GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH LIMIT VALUE));
ALTER TABLE tipo_temporada     MODIFY (id_tipo_temporada   GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH LIMIT VALUE));
ALTER TABLE usuario_sistema    MODIFY (id_usuario          GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH LIMIT VALUE));
ALTER TABLE alojamiento        MODIFY (id_alojamiento      GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH LIMIT VALUE));
ALTER TABLE habitacion         MODIFY (id_habitacion       GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH LIMIT VALUE));
ALTER TABLE temporada          MODIFY (id_temporada        GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH LIMIT VALUE));
ALTER TABLE cliente            MODIFY (id_cliente          GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH LIMIT VALUE));
ALTER TABLE reserva            MODIFY (id_reserva          GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH LIMIT VALUE));
ALTER TABLE reserva_habitacion MODIFY (id_reserva_hab      GENERATED BY DEFAULT ON NULL AS IDENTITY (START WITH LIMIT VALUE));

-- Estadísticas del optimizador: sin ellas los planes de ejecución de

BEGIN
  DBMS_STATS.GATHER_SCHEMA_STATS(ownname => USER);
  DBMS_OUTPUT.PUT_LINE('14. Estadísticas recolectadas.');
END;
/


/* =====================================================================
   15. VERIFICACIÓN
   ===================================================================== */

-- 15.1 Volumen: filas por tabla frente al mínimo del enunciado.

SELECT tabla, filas, minimo,
       CASE WHEN minimo IS NULL OR filas >= minimo THEN 'OK' ELSE 'FALTA' END AS estado
FROM (
  SELECT 'MUNICIPIO'          tabla, COUNT(*) filas, 12    minimo FROM municipio          UNION ALL
  SELECT 'TIPO_ALOJAMIENTO',         COUNT(*),       4            FROM tipo_alojamiento   UNION ALL
  SELECT 'ALOJAMIENTO',              COUNT(*),       60           FROM alojamiento        UNION ALL
  SELECT 'HABITACION',               COUNT(*),       400          FROM habitacion         UNION ALL
  SELECT 'TEMPORADA',                COUNT(*),       6            FROM temporada          UNION ALL
  SELECT 'TARIFA',                   COUNT(*),       NULL         FROM tarifa             UNION ALL
  SELECT 'CLIENTE',                  COUNT(*),       3000         FROM cliente            UNION ALL
  SELECT 'RESERVA',                  COUNT(*),       25000        FROM reserva            UNION ALL
  SELECT 'RESERVA_HABITACION',       COUNT(*),       25000        FROM reserva_habitacion UNION ALL
  SELECT 'RESERVA_NOCHE',            COUNT(*),       NULL         FROM reserva_noche      UNION ALL
  SELECT 'PAGO',                     COUNT(*),       25000        FROM pago               UNION ALL
  SELECT 'CANCELACION',              COUNT(*),       NULL         FROM cancelacion        UNION ALL
  SELECT 'SERVICIO',                 COUNT(*),       30           FROM servicio           UNION ALL
  SELECT 'RESERVA_SERVICIO',         COUNT(*),       40000        FROM reserva_servicio   UNION ALL
  SELECT 'RESENA',                   COUNT(*),       NULL         FROM resena             UNION ALL
  SELECT 'USUARIO_SISTEMA',          COUNT(*),       10           FROM usuario_sistema
);

-- 15.2 TARIFA = habitaciones x temporadas (se deriva del cruce).

SELECT (SELECT COUNT(*) FROM habitacion) * (SELECT COUNT(*) FROM temporada) AS esperado,
       (SELECT COUNT(*) FROM tarifa)                                         AS real
FROM   dual;

-- 15.3 Reseñas: porcentaje sobre las reservas completadas (mínimo 40 %).

SELECT c.completadas, r.resenas, ROUND(100 * r.resenas / NULLIF(c.completadas, 0), 1) AS porcentaje
FROM   (SELECT COUNT(*) AS completadas FROM reserva WHERE estado = 'COMPLETADA') c
CROSS  JOIN (SELECT COUNT(*) AS resenas FROM resena) r;

-- 15.4 Asimetría: habitaciones por tipo de alojamiento.

SELECT ta.nombre AS tipo, COUNT(DISTINCT a.id_alojamiento) AS alojamientos,
       MIN(n) AS min_hab, MAX(n) AS max_hab, ROUND(AVG(n), 1) AS prom_hab
FROM   (SELECT id_alojamiento, COUNT(*) n FROM habitacion GROUP BY id_alojamiento) h
JOIN   alojamiento a       ON a.id_alojamiento = h.id_alojamiento
JOIN   tipo_alojamiento ta ON ta.id_tipo_alojamiento = a.id_tipo_alojamiento
GROUP  BY ta.nombre
ORDER  BY max_hab DESC;

-- 15.5 Asimetría: reservas por municipio.

SELECT m.nombre AS municipio, COUNT(DISTINCT a.id_alojamiento) AS alojamientos, COUNT(r.id_reserva) AS reservas
FROM   municipio m
LEFT   JOIN alojamiento a ON a.id_municipio   = m.id_municipio
LEFT   JOIN reserva r     ON r.id_alojamiento = a.id_alojamiento
GROUP  BY m.nombre
ORDER  BY reservas DESC;

-- 15.6 Estacionalidad: reservas por mes de llegada en 2025.

SELECT TO_CHAR(fecha_checkin, 'MM') AS mes, COUNT(*) AS reservas
FROM   reserva
WHERE  EXTRACT(YEAR FROM fecha_checkin) = 2025
GROUP  BY TO_CHAR(fecha_checkin, 'MM')
ORDER  BY mes;

-- 15.7 Reservas por estado.

SELECT estado, COUNT(*) AS reservas FROM reserva GROUP BY estado ORDER BY reservas DESC;

-- 15.8 Integridad: solapamientos entre reservas no canceladas (debe dar 0).

SELECT COUNT(*) AS solapamientos
FROM   reserva_habitacion a
JOIN   reserva ra ON ra.id_reserva = a.id_reserva
JOIN   reserva_habitacion b ON b.id_habitacion = a.id_habitacion
                           AND b.id_reserva_hab > a.id_reserva_hab
JOIN   reserva rb ON rb.id_reserva = b.id_reserva
WHERE  ra.estado <> 'CANCELADA'
AND    rb.estado <> 'CANCELADA'
AND    a.fecha_checkin < b.fecha_checkout
AND    b.fecha_checkin < a.fecha_checkout;

-- 15.9 Integridad: cada noche de cada línea tiene su fila en RESERVA_NOCHE.

SELECT (SELECT SUM(fecha_checkout - fecha_checkin) FROM reserva_habitacion) AS noches_esperadas,
       (SELECT COUNT(*) FROM reserva_noche)                                 AS noches_generadas
FROM   dual;

-- 15.10 Integridad: temporadas sin huecos ni solapes (debe dar 0).

SELECT COUNT(*) AS huecos_o_solapes
FROM  (SELECT fecha_inicio, LAG(fecha_fin) OVER (ORDER BY fecha_inicio) AS fin_anterior
       FROM   temporada)
WHERE  fin_anterior IS NOT NULL
AND    fecha_inicio <> fin_anterior + 1;

-- 15.11 Ejemplo de la decisión de diseño 2: estadías que cruzan temporadas.

SELECT COUNT(*) AS lineas_que_cruzan_temporadas
FROM  (SELECT rn.id_reserva_hab
       FROM   reserva_noche rn
       JOIN   tarifa ta ON ta.id_tarifa = rn.id_tarifa
       GROUP  BY rn.id_reserva_hab
       HAVING COUNT(DISTINCT ta.id_temporada) > 1);

-- 15.12 Servicios: líneas por reserva y cantidades (deben variar, no ser todas las combinaciones posibles).

SELECT COUNT(DISTINCT id_reserva)                       AS reservas_con_servicios,
       COUNT(*)                                         AS lineas,
       ROUND(COUNT(*) / COUNT(DISTINCT id_reserva), 1)  AS lineas_por_reserva,
       MIN(cantidad)                                    AS cant_min,
       MAX(cantidad)                                    AS cant_max,
       ROUND(AVG(cantidad), 2)                          AS cant_prom
FROM   reserva_servicio;

/* Fin del script de carga */