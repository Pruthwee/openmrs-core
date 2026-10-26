/**
 * This Source Code Form is subject to the terms of the Mozilla Public License,
 * v. 2.0. If a copy of the MPL was not distributed with this file, You can
 * obtain one at http://mozilla.org/MPL/2.0/. OpenMRS is also distributed under
 * the terms of the Healthcare Disclaimer located at http://openmrs.org/license.
 *
 * Copyright (C) OpenMRS Inc. OpenMRS is a registered trademark and the OpenMRS
 * graphic logo is a trademark of OpenMRS Inc.
 */
package org.openmrs.web.filter.initialization;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.util.Properties;

import org.openmrs.util.DatabaseUtil;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class DatabaseDetective {

	private static final String CONNECTION_URL = "connection.url";

	private static final String CONNECTION_DRIVER_CLASS = "connection.driver_class";

	private static final String CONNECTION_USERNAME = "connection.username";

	private static final String CONNECTION_PASSWORD = "connection.password";

	private static final Logger log = LoggerFactory.getLogger(DatabaseDetective.class);

	/**
	 * Check whether openmrs database is empty. Having just one non-liquibase table in the given
	 * database qualifies this as a non-empty database.
	 *
	 * @param props the runtime properties
	 * @return true if the openmrs database is empty or does not exist yet
	 */
	public boolean isDatabaseEmpty(Properties props) {
		if (props == null) {
			return true;
		}

		try {
			DatabaseUtil.loadDatabaseDriver(props.getProperty(CONNECTION_URL),
			    props.getProperty(CONNECTION_DRIVER_CLASS, null));

			try (Connection connection = DriverManager.getConnection(props.getProperty(CONNECTION_URL),
			    props.getProperty(CONNECTION_USERNAME), props.getProperty(CONNECTION_PASSWORD));
			        ResultSet tbls = connection.getMetaData().getTables(null, null, null, new String[] { "TABLE" })) {

				//get all tables
				while (tbls.next()) {
					String tableName = tbls.getString("TABLE_NAME");
					String tableSchema = tbls.getString("TABLE_SCHEM");
					String schema = tableSchema != null ? tableSchema.toLowerCase() : "";

					//if any public table exist besides "liquibasechangelog" or "liquibasechangeloglock", return false
					if ((schema.isEmpty() || "public".equals(schema)) && !("liquibasechangelog".equalsIgnoreCase(tableName))
					        && !("liquibasechangeloglock".equalsIgnoreCase(tableName))) {
						return false;
					}
				}
				return true;
			} catch (Exception e) {
				// A configured instance (connection URL set) that we cannot reach is unreachable, not
				// empty. Reporting it empty here would reopen the unauthenticated setup wizard on an
				// already-configured deployment during a database outage, so only a genuinely
				// unconfigured instance (no connection URL) counts as empty.
				String url = props.getProperty(CONNECTION_URL);
				return url == null || url.isBlank();
			}
		} catch (Exception e) {
			log.warn("Error while checking database", e);
			String url = props.getProperty(CONNECTION_URL);
			return url == null || url.isBlank();
		}
	}
}
