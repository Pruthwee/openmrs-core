/**
 * This Source Code Form is subject to the terms of the Mozilla Public License,
 * v. 2.0. If a copy of the MPL was not distributed with this file, You can
 * obtain one at http://mozilla.org/MPL/2.0/. OpenMRS is also distributed under
 * the terms of the Healthcare Disclaimer located at http://openmrs.org/license.
 *
 * Copyright (C) OpenMRS Inc. OpenMRS is a registered trademark and the OpenMRS
 * graphic logo is a trademark of OpenMRS Inc.
 */
package org.openmrs.util;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

public class OpenmrsThreadPoolHolder {

	private static final int PROCESSORS = Runtime.getRuntime().availableProcessors();

	public static final ExecutorService threadExecutor = new ThreadPoolExecutor(Math.max(1, PROCESSORS / 2),
	        Math.max(2, PROCESSORS * 2), 60L, TimeUnit.SECONDS, new LinkedBlockingQueue<>(1000),
	        new ThreadPoolExecutor.CallerRunsPolicy());
}
