-- Dropnutí tabulek, pokud již existují
DROP TABLE IF EXISTS bindings;
DROP TABLE IF EXISTS attrs;
DROP TABLE IF EXISTS leasings;
DROP TABLE IF EXISTS docs;
DROP TABLE IF EXISTS items;
DROP TABLE IF EXISTS users;

-- Tabulka uživatelů
CREATE TABLE users (
   id SERIAL PRIMARY KEY,
   name TEXT NOT NULL,
   password TEXT NOT NULL,
   creator INTEGER,
   ctime TIMESTAMP WITH TIME ZONE DEFAULT now(),
   admin BOOLEAN NOT NULL
);

-- Tabulka dokumentů
CREATE TABLE docs
(
  id SERIAL PRIMARY KEY,
  creator INTEGER NOT NULL
);

-- Tabulka pronájmů
CREATE TABLE leasings (
  lessee INTEGER REFERENCES users(id),
  doc_id INTEGER REFERENCES docs(id)
);

-- Tabulka hodnot
CREATE TABLE items
(
  id SERIAL PRIMARY KEY,
  value TEXT NOT NULL
);

-- Tabulka atributů
CREATE TABLE attrs
(
  id SERIAL PRIMARY KEY,
  holder INTEGER NOT NULL REFERENCES docs (id),
  name TEXT NOT NULL,
  container BOOLEAN NOT NULL,
  link BOOLEAN NOT NULL
);

-- Spojovací tabulka
CREATE TABLE bindings
(
  seqnum BIGSERIAL PRIMARY KEY,
  attr_id INTEGER REFERENCES attrs(id),
  btime TIMESTAMP NOT NULL DEFAULT now(),
  item_id INTEGER REFERENCES items(id),
  doc_id INTEGER REFERENCES docs(id),
  operation SMALLINT NOT NULL -- 0 set, 1 reset, 2 insert, 3 remove
);

-- Dropnutí funkcí, pokud již existují
DROP FUNCTION IF EXISTS create_user(TEXT, TEXT, BOOLEAN, INT, TEXT);
DROP FUNCTION IF EXISTS create_first_user(TEXT);
DROP FUNCTION IF EXISTS uid(TEXT);
DROP FUNCTION IF EXISTS credentials(INTEGER, TEXT, BOOLEAN);
DROP FUNCTION IF EXISTS permission(INTEGER, TEXT, INTEGER);
DROP FUNCTION IF EXISTS user_name(INT);
DROP FUNCTION IF EXISTS lease(INT, INT, TEXT, INT);
DROP FUNCTION IF EXISTS remove_lease(INT, INT, TEXT, INT);
DROP FUNCTION IF EXISTS insert_doc (INTEGER, TEXT);
DROP FUNCTION IF EXISTS set_attr(INTEGER, TEXT, TEXT, BOOLEAN, INTEGER, TEXT);
DROP FUNCTION IF EXISTS reset_attr(INTEGER, TEXT, INTEGER, TEXT);
DROP FUNCTION IF EXISTS remove_attr(INTEGER, TEXT, TEXT, INTEGER, TEXT);
DROP FUNCTION IF EXISTS insert_attr(INTEGER, TEXT, TEXT, BOOLEAN, INTEGER, TEXT);
DROP FUNCTION IF EXISTS list_docs(INTEGER, TEXT);
DROP FUNCTION IF EXISTS list_lessees(INTEGER, INTEGER, TEXT);
DROP FUNCTION IF EXISTS scandocs (INTEGER, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS isAdmin(usr INTEGER);
DROP FUNCTION IF EXISTS isCreator(doc INTEGER, usr INTEGER);
DROP FUNCTION IF EXISTS list_users(usr INTEGER, passwd TEXT);
DROP FUNCTION IF EXISTS list_all_docs(usr INTEGER, passwd TEXT);
DROP FUNCTION IF EXISTS get_scheme_id (doc INTEGER, usr INTEGER, passwd TEXT);
DROP FUNCTION IF EXISTS get_name (doc INTEGER, usr INTEGER, passwd TEXT);
DROP FUNCTION IF EXISTS has_shadow (doc INTEGER, usr INTEGER, passwd TEXT);

-- Funkce pro vytvoření uživatele
CREATE FUNCTION create_user(name TEXT, passwd TEXT, 
                            admin BOOLEAN, creator INT, 
                            creatorPassword TEXT) 
    RETURNS integer
AS $$
   DECLARE
   	uid INT;
   BEGIN
   	-- Otestování údajů uživatele
    PERFORM credentials(creator, creatorPassword, true);
	-- Vložení uživatele do databáze
    INSERT INTO users (name, password, creator, admin) 
          VALUES (name, md5(name||passwd), creator, admin) RETURNING id INTO uid;
    RETURN uid;          
   END       
$$ LANGUAGE plpgsql;

-- Funkce pro vytvoření prvního uživatele - bez kontroly údajů
CREATE FUNCTION create_first_user(password TEXT) 
    RETURNS integer
 AS $$
 	-- Vložení uživatele do databáze
    INSERT INTO users (name, password, creator, admin) 
          VALUES ('admin', md5('admin'||password), -1, true) RETURNING id;
 $$ LANGUAGE SQL;

-- Funkce pro získání identifikátoru uživatele
CREATE FUNCTION uid(usr TEXT)
    RETURNS integer 
AS $$
    SELECT id FROM users WHERE name = usr;
$$ LANGUAGE sql;

-- Funkce pro ověření údajů uživatele
CREATE FUNCTION credentials(usr INTEGER, passwd TEXT, 
                            ensureAdmin BOOLEAN DEFAULT false)
    RETURNS void
AS $$
    DECLARE 
		rpass TEXT;
		uname TEXT;
    	isAdmin BOOLEAN;
    BEGIN
        PERFORM pg_sleep(0.1);
		-- Získání a otestování existence uživatele
        SELECT name FROM users WHERE usr = id INTO uname;
        SELECT password FROM users WHERE usr = id INTO rpass;
		IF uname IS NULL OR rpass <> md5(uname||passwd) THEN
	   		RAISE EXCEPTION 'Invalid credentials';
		END IF;
		-- Otestování na administrátorská práva, pokud je to vyžadováno
		IF ensureAdmin THEN
			SELECT admin FROM users WHERE usr = id INTO isAdmin;
			IF NOT isAdmin THEN
				RAISE EXCEPTION 'User is not an admin';
			END IF;
		END IF;
    END
$$ LANGUAGE plpgsql;

-- Funkce pro zjištění práv k dokumentu
CREATE FUNCTION permission(usr INTEGER, passwd TEXT, doc INTEGER)
    RETURNS void
AS $$
    DECLARE 
		creator_id INTEGER;
		leasingCount INTEGER;
    BEGIN
		-- Otestování údajů
        PERFORM credentials(usr, passwd);
		-- Získání tvůrce dokumentu
		SELECT creator FROM docs WHERE doc = id INTO creator_id;
		-- Pokud je tvůrce různý od dotazovaného uživatele, testuje se, zda uživateli není dokument propůjčen, jinak vyvolá vyjímku
		IF creator_id <> usr THEN
	   		SELECT COUNT(*) FROM leasings WHERE usr = lessee AND doc = leasings.doc_id 
	      		INTO leasingCount;
	   		IF leasingCount = 0 THEN
				RAISE EXCEPTION 'User % has no permission to edit document with id %', usr, doc;
	   		END IF;	
		END IF;
    END
$$ LANGUAGE plpgsql;

-- Funkce pro získání jména uživatele
CREATE FUNCTION user_name(uid INT) 
   RETURNS TEXT
AS $$
	SELECT name FROM users WHERE uid = id;
$$ LANGUAGE sql;

-- Funkce pro propůjčení dokumentu
CREATE FUNCTION lease(doc INT, lessor INT, passwd TEXT, lssee INT)
    RETURNS void
AS $$
	DECLARE
    	ls INTEGER;
    BEGIN
		-- Otestování práv k dokumentu
    	PERFORM permission(lessor, passwd, doc);
		-- Zajištění existence uživatele
    	IF user_name(lssee) IS NULL THEN
       		RAISE EXCEPTION 'User % does not exist', lssee;
    	END IF;
		-- Zjištění, zda už dokument není uživateli propůjčen
    	SELECT lessee FROM leasings WHERE leasings.lessee = lssee AND leasings.doc_id = doc INTO ls;
    	IF ls IS NOT NULL THEN
    		RAISE EXCEPTION 'User % is already a lessee', ls;
    	END IF;
		-- Vytvoření propůjčení
    	INSERT INTO leasings (lessee, doc_id) VALUES (lssee, doc);
    END
$$ LANGUAGE plpgsql;

-- Funkce pro odstranění propůjčení
CREATE FUNCTION remove_lease(doc INT, lessor INT, passwd TEXT, lssee INT)
    RETURNS void
AS $$
    BEGIN
		-- Otestování práv k dokumentu
    	PERFORM permission(lessor, passwd, doc);
		-- Zajištění existence uživatele
    	IF user_name(lssee) IS NULL THEN
       		RAISE EXCEPTION 'User % does not exist', lssee;
    	END IF;
		-- Odstranění propůjčení
    	DELETE FROM leasings WHERE leasings.lessee = lssee AND leasings.doc_id = doc;
    END
$$ LANGUAGE plpgsql;

-- Funkce pro vytvoření dokumentu
CREATE FUNCTION insert_doc(creator INTEGER, passwd TEXT)
  RETURNS INTEGER
AS $$
    DECLARE 
    	rv INTEGER;
    BEGIN
		-- Otestování údajů uživatele
       	PERFORM credentials(creator, passwd);
		-- Vložení dokumentu do databáze
       	INSERT INTO docs (creator) VALUES (creator) RETURNING id INTO rv;
       	RETURN rv;
    END
$$ LANGUAGE plpgsql;

-- Funkce pro vložení nekontejnerového atributu
CREATE FUNCTION set_attr(doc INTEGER, _name TEXT, _value TEXT, _link BOOLEAN, usr INTEGER, passwd TEXT) 
  RETURNS void
AS $$
  DECLARE
     item INTEGER;
     attr INTEGER;
  BEGIN
	-- Otestování práv uživatele
	PERFORM permission(usr, passwd, doc);
	-- Otestování existence hodnoty
    SELECT id FROM items WHERE items.value = _value INTO item;
    IF item  IS NULL THEN
		INSERT INTO items (value) VALUES (_value) RETURNING id INTO item;
	END IF;
	-- Otestování existence atributu
	SELECT id FROM attrs WHERE attrs.name = _name  AND holder = doc INTO attr;
	IF attr IS NULL THEN
		INSERT INTO attrs (holder, name, container, link) VALUES (doc, _name, FALSE, _link) RETURNING id INTO attr;
	END IF;
	-- Propojení atributu s hodnotou
	INSERT INTO bindings (attr_id, item_id, doc_id, operation) VALUES(attr, item, NULL, 0);
  END
$$ LANGUAGE  plpgsql;

-- Funkce pro odstranění atributu z dokumentu
CREATE FUNCTION reset_attr(doc_id INTEGER, _name TEXT, usr INTEGER, passwd TEXT)
  RETURNS void
AS $$
  DECLARE
    attr INTEGER;
  BEGIN
  	-- Otestování práv uživatele
    PERFORM permission(usr, passwd, doc_id);
	-- Otestování existence atributu v dokumentu
    SELECT id FROM attrs WHERE attrs.name = _name  AND holder = doc_id INTO attr;
    IF attr IS NULL THEN
		RAISE EXCEPTION 'Unknown attribute % of document with id %', _name, doc_id;
    END IF;
	-- Odstranění atributu
    INSERT INTO bindings (attr_id, item_id, doc_id, operation) VALUES(attr, NULL, NULL, 1);
  END  
$$ LANGUAGE  plpgsql;

-- Funkce pro odstranění atributu z pole
CREATE FUNCTION remove_attr(doc_id INTEGER, _name TEXT, _value TEXT, usr INTEGER, passwd TEXT)
  RETURNS void
AS $$
  DECLARE
    attr INTEGER;
    cont BOOLEAN;
    item INTEGER;
  BEGIN
  	-- Otestování práv uživatele
    PERFORM permission(usr, passwd, doc_id);
	-- Otestování existence atributu a zda je kontejner
    SELECT id, container INTO attr, cont FROM attrs WHERE attrs.name = _name  AND holder = doc_id;
    IF attr IS NULL THEN
		RAISE EXCEPTION 'Unknown attribute % of document with id %', _name, doc_id;
    END IF;
    IF NOT cont THEN
    	RAISE EXCEPTION 'Attribute % of document % is not a container', _name, doc_id;
    END IF;
	-- Otestování existence hodnoty atributu
    SELECT id FROM items WHERE items.value = _value INTO item;
    IF item IS NULL THEN
		RAISE EXCEPTION 'Unknown value % of attribute %', _value, _name;
    END IF;
	-- Odstranění atributu
    INSERT INTO bindings (attr_id, item_id, doc_id, operation) VALUES(attr, item, NULL, 3);
  END  
$$ LANGUAGE  plpgsql;

-- Funkce pro vložení kontejnerového atributu
CREATE FUNCTION insert_attr(doc INTEGER, _name TEXT, _value TEXT, _link BOOLEAN, usr INTEGER, passwd TEXT)
  RETURNS void
AS $$
  DECLARE
     attr INTEGER;
     cont BOOLEAN;
     item INTEGER;
  BEGIN
  	-- Otestování práv uživatele
    PERFORM permission(usr, passwd, doc);
	-- Otestování existence atributu a zda je kontejner
    SELECT id, container INTO attr, cont FROM attrs WHERE attrs.name = _name  AND holder = doc;
    IF attr IS NULL THEN
    	INSERT INTO attrs (holder, name, container, link) VALUES (doc, _name, TRUE, _link) RETURNING id, container INTO attr, cont;
    END IF;
    IF NOT cont THEN
    	RAISE EXCEPTION 'Attribute % of document % is not a container', _name, doc;
    END IF;
	-- Otestování existence hodnoty atributu
    SELECT id FROM items WHERE items.value = _value INTO item;
    IF item  IS NULL THEN
        INSERT INTO items (value) VALUES (_value) RETURNING id INTO item;
    END IF;
	-- Vložení atributu
    INSERT INTO bindings (attr_id, item_id, doc_id, operation) VALUES(attr, item, NULL, 2);
  END  
$$ LANGUAGE  plpgsql;

-- Funkce pro získání seznamu dokumentů daného uživatele
CREATE FUNCTION list_docs (usr INTEGER, passwd TEXT)
  RETURNS TABLE(id INTEGER, name TEXT)
AS $$
	DECLARE
		r RECORD;
    	a RECORD;
	BEGIN
		-- Ověření údajů uživatele
  		PERFORM credentials(usr, passwd);
		-- Vytvoření dočasné tabulky
  		CREATE TEMP TABLE temp_docs(id INTEGER, name TEXT);
		-- Procházení neduplicitních záznamů o dokumentech
  		FOR r IN SELECT DISTINCT docs.id 
  		   		FROM docs 
           		LEFT JOIN leasings ON docs.id = leasings.doc_id 
           		WHERE docs.creator = usr OR leasings.lessee = usr
           		ORDER BY docs.id
  		LOOP
			-- Procházení atributů dokumentu a nalezení názvu
  			FOR a IN SELECT * FROM scandocs(r.id, now()) LOOP
    			IF a.name = '_id' THEN
        			INSERT INTO temp_docs VALUES (r.id, a.value);
        			EXIT;
        		END IF;
    		END LOOP;
  		END LOOP;
		-- Vrácení všech uložených údajů
  		RETURN QUERY SELECT * FROM temp_docs ORDER BY temp_docs.name;
  		DROP TABLE temp_docs;
  		RETURN;
	END
$$ LANGUAGE plpgsql;

-- Funkce pro získání seznamu nájemníků
CREATE FUNCTION list_lessees (doc INTEGER, usr INTEGER, passwd TEXT)
  RETURNS TABLE(id INTEGER, name TEXT)
AS $$
	DECLARE
  		ctr INTEGER;
	BEGIN
		-- Otestování údajů uživatele
  		PERFORM credentials(usr, passwd);
		-- Otestování, zda je uživatel tvůrce
  		SELECT docs.id FROM docs WHERE docs.id = doc AND docs.creator = usr INTO ctr;
  		IF ctr IS NULL THEN
    		RAISE EXCEPTION 'User % is not the creator.', usr;
  		END IF;
		-- Získání seznamu nájemníků
  		RETURN QUERY SELECT users.id, users.name FROM users JOIN leasings ON users.id = leasings.lessee WHERE leasings.doc_id = doc;
	END
$$ LANGUAGE plpgsql;

-- Funkce pro získání seznamu atributů k určité časové značce
CREATE FUNCTION scandocs (doc INTEGER, deadline TIMESTAMPTZ)
  RETURNS TABLE(name TEXT, value TEXT, container BOOLEAN, link BOOLEAN, holder INTEGER)
AS $$
	DECLARE
  		r RECORD;
	BEGIN
		-- Vytvoření dočasné tabulky pro uložení atributů
		CREATE TEMP TABLE temp_attrs(name TEXT, value TEXT, container BOOLEAN, link BOOLEAN, holder INTEGER);
		-- Procházení všech atributů podle operací při propojování s hodnotami
  		FOR r in SELECT attrs.name as name,
  				  		attrs.container as container,
                  		attrs.link as link,
                  		attrs.holder as holder,
                  		bindings.btime as btime,
                  		bindings.operation as operation,
                  		docs.id as doc_id,
                  		items.value as value
           			FROM attrs
             		JOIN bindings ON attrs.id = bindings.attr_id
             		LEFT JOIN docs ON bindings.doc_id = docs.id
             		LEFT JOIN items ON bindings.item_id = items.id
           		WHERE attrs.holder = doc AND bindings.btime <= deadline
          		ORDER BY btime ASC
  		LOOP
			-- Operace je vložením nekontejnerového atributu
      		IF r.operation = 0 THEN
				INSERT INTO temp_attrs VALUES (r.name, r.value, r.container, r.link, r.holder);
			-- Operace je odstraněním atributu
      		ELSIF r.operation = 1 THEN
        		DELETE FROM temp_attrs WHERE temp_attrs.name = r.name;
			-- Operace je vložením kontejnerového atributu
      		ELSIF r.operation = 2 THEN
				INSERT INTO temp_attrs VALUES (r.name, r.value, r.container, r.link, r.holder);
			-- Operace je odstraněním (Kontejnerového) atributu z pole
      		ELSIF r.operation = 3 THEN
				DELETE FROM temp_attrs WHERE temp_attrs.name = r.name AND temp_attrs.value = r.value;
      		END IF;
  		END LOOP;
		-- Vrácení všech získaných informací
  		RETURN QUERY SELECT * FROM temp_attrs;
  		DROP TABLE temp_attrs;
  		RETURN;
	END
$$ LANGUAGE plpgsql;

-- Funkce pro zjištění, zda je uživatel adminem
CREATE FUNCTION isAdmin(usr INTEGER)
    RETURNS BOOLEAN
AS $$
    SELECT admin FROM users WHERE id = usr;
$$ LANGUAGE sql;

-- Funkce pro zjištění, zda je uživatel tvůrcem dokumentu
CREATE FUNCTION isCreator(doc INTEGER, usr INTEGER)
    RETURNS BOOLEAN
AS $$
DECLARE
	creator_id INTEGER;
BEGIN
    SELECT creator FROM docs WHERE id = doc INTO creator_id;
    IF creator_id = usr THEN
    	RETURN TRUE;
    ELSE
    	RETURN FALSE;
    END IF;
END
$$ LANGUAGE plpgsql;

-- Funkce pro získání seznamu uživatelů
CREATE FUNCTION list_users(usr INTEGER, passwd TEXT)
    RETURNS TABLE(name TEXT)
AS $$
	BEGIN
		-- Otestování údajů uživatele
		PERFORM credentials(usr, passwd);
		-- Vrácení seznamu uživatelů
    	RETURN QUERY SELECT users.name FROM users WHERE id <> usr;
	END;
$$ LANGUAGE plpgsql;

-- Funkce pro získání seznamu všech (pojmenovaných) dokumentů
CREATE FUNCTION list_all_docs(usr INTEGER, passwd TEXT)
    RETURNS TABLE(id INTEGER, name TEXT)
AS $$
	DECLARE
		r RECORD;
    	a RECORD;
	BEGIN
		-- Otestování údajů uživatele
  		PERFORM credentials(usr, passwd);
		-- Vytvoření dočasné tabulky pro uložení informací
  		CREATE TEMP TABLE temp_docs(id INTEGER, name TEXT);
		-- Procházení neduplicitních záznamů o dokumentech
  		FOR r IN SELECT DISTINCT docs.id 
  		   		FROM docs 
           		LEFT JOIN leasings ON docs.id = leasings.doc_id 
           		ORDER BY docs.id
  		LOOP
			-- Procházení atributů dokumentu a hledání názvu
  			FOR a IN SELECT * FROM scandocs(r.id, now()) LOOP
    			IF a.name = '_id' THEN
        			INSERT INTO temp_docs VALUES (r.id, a.value);
        			EXIT;
        		END IF;
    		END LOOP;
  		END LOOP;
		-- Vrácení všech informací
  		RETURN QUERY SELECT * FROM temp_docs ORDER BY temp_docs.name;
  		DROP TABLE temp_docs;
  		RETURN;
	END
$$ LANGUAGE plpgsql;

-- Funkce pro získání identifikátoru schématu
CREATE FUNCTION get_scheme_id (doc INTEGER, usr INTEGER, passwd TEXT)
  RETURNS INTEGER
AS $$
	DECLARE
    	a RECORD;
	BEGIN
		-- Otestování údajů uživatele
  		PERFORM credentials(usr, passwd);
		-- Procházení atributů dokumentu a hledání schématu
    	FOR a IN SELECT * FROM scandocs(doc, now()) LOOP
        	IF a.name = '_scheme' THEN
            	RETURN cast(substring(a.value from 2 for (char_length(a.value)-1)) as INTEGER);
            	EXIT;
        	END IF;
    	END LOOP;
    	RETURN -1;
	END
$$ LANGUAGE plpgsql;

-- Funkce pro získání názvu dokumentu
CREATE FUNCTION get_name (doc INTEGER, usr INTEGER, passwd TEXT)
  RETURNS TEXT
AS $$
	DECLARE
    	a RECORD;
	BEGIN
		-- Otestování údajů uživatele
  		PERFORM credentials(usr, passwd);
		-- Procházení atributů dokumentu a hledání názvu
    	FOR a IN SELECT * FROM scandocs(doc, now()) LOOP
        	IF a.name = '_id' THEN
            	RETURN a.value;
            	EXIT;
        	END IF;
    	END LOOP;
    	RETURN '';
	END
$$ LANGUAGE plpgsql;

-- Funkce pro zjištění, zda je dokument odvozen
CREATE FUNCTION has_shadow (doc INTEGER, usr INTEGER, passwd TEXT)
  RETURNS BOOLEAN
AS $$
	DECLARE
    	a RECORD;
	BEGIN
		-- Otestování údajů uživatele
  		PERFORM credentials(usr, passwd);
		-- Procházení atributů a hledání stínového dokumentu
    	FOR a IN SELECT * FROM scandocs(doc, now()) LOOP
        	IF a.name = '_shadow' THEN
            	RETURN TRUE;
            	EXIT;
        	END IF;
    	END LOOP;
    	RETURN FALSE;
	END
$$ LANGUAGE plpgsql;

------------------------------------------------------------------------

-- Vytvoření prvního uživatele
SELECT create_first_user('Gandalf');